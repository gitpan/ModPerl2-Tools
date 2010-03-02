# please insert nothing before this line: -*- mode: cperl; cperl-indent-level: 4; cperl-continued-statement-offset: 4; indent-tabs-mode: nil -*-

package ModPerl2::Tools;

use 5.008008;
use strict;
use warnings;
no warnings 'uninitialized';

use Apache2::RequestUtil ();
use POSIX ();

our $VERSION = '0.01';

sub close_fd {
    my %save=(2=>1);       # keep STDERR
    undef @save{@{$_[0]}} if( @_ and ref $_[0] eq 'ARRAY' );

    if( $^O eq 'linux' and opendir my $d, "/proc/self/fd" ) {
        while (defined(my $fd=readdir $d)) {
            next unless $fd=~/^\d+$/;
            POSIX::close $fd unless exists $save{$fd};
        }
    } else {
        my $max_fd=POSIX::sysconf(&POSIX::_SC_OPEN_MAX);
        $max_fd=1000 unless $max_fd>0;
        for( my $fd=0; $fd<$max_fd; $fd++ ) {
            POSIX::close $fd unless exists $save{$fd};
        }
    }

    # now reopen std{in,out} on /dev/null
    open(STDIN,  '<', '/dev/null') unless exists $save{0};
    open(STDIN,  '>', '/dev/null') unless exists $save{1};
}

sub spawn {
    my ($daemon_should_survive_apache_restart, @args)=@_;

    local $SIG{CHLD}='IGNORE';
    my $pid;
    pipe my ($rd, $wr) or return;
    # yes, even fork can fail
    select undef, undef, undef, .1 while( !defined($pid=fork) );
    unless( $pid ) {            # child
        close $rd;
        # 2nd fork to cut parent relationship with a mod_perl apache
        select undef, undef, undef, .1 while( !defined($pid=fork) );
        if( $pid ) {
            print $wr $pid;
            close $wr;
            POSIX::_exit 0;
        } else {
            close $wr;
            if( ref($daemon_should_survive_apache_restart) ) {
                close_fd($daemon_should_survive_apache_restart->{keep_fd});
                POSIX::setsid if( $daemon_should_survive_apache_restart->{survive} );
            } else {
                close_fd;
                POSIX::setsid if( $daemon_should_survive_apache_restart );
            }

            if( 'CODE' eq ref $args[0] ) {
                my $f=shift @args;
                # TODO: restore %ENV and exit() behavior
                eval {$f->(@args)};
                CORE::exit 0;
            } else {
                {exec @args;}         # extra block to suppress a warning
                POSIX::_exit -1;
            }
        }
    }
    close $wr;
    $pid=readline $rd;
    waitpid $pid, 0;            # avoid a zombie on some OS

    return $pid;
}

sub safe_die {
    my ($status)=@_;

    Apache2::RequestUtil->request->safe_die($status);
}

sub fetch_url {
    my ($url)=@_;

    Apache2::RequestUtil->request->fetch_url($url);
}

{
    package Apache2::Filter;

    use Apache2::Filter ();
    use Apache2::FilterRec ();
    use Apache2::HookRun ();
    use Apache2::Const -compile=>qw/OK/;

    use constant {
        HTTP_HEADER_FILTER_NAME => 'http_header',
    };

    sub _safe_die {
        my ($I, $status)=@_;

        # Check if we still can send an error message or better check if
        # any output has already been sent. If so the HTTP_HEADER filter
        # is missing in the output chain. If it is still present we can
        # send a normal error message, see ap_die() in
        # httpd-2.2.x/modules/http/http_request.c.

        for( my $n=$I->next; $n; $n=$n->next ) {
            if( $n->frec->name eq HTTP_HEADER_FILTER_NAME ) {
                $I->r->die($status);
                last;
            }
        }

        return Apache2::Const::OK;
    }

    sub safe_die {
        my ($I, $status)=@_;

        # avoid further invocation
        $I->remove;

        return $I->_safe_die($status);
    }
}

{
    package ModPerl2::Tools::Filter;

    use Apache2::Filter ();
    use APR::Brigade ();
    use APR::Bucket ();
    use base 'Apache2::Filter';
    use Apache2::Const -compile=>qw/OK DECLINED HTTP_OK/;

    sub read_bb {
        my ($bb, $buffer)=@_;

        my $eos=0;

        while( my $b=$bb->first ) {
            $eos++ if( $b->is_eos );
            $b->read(my $bdata);
            push @{$buffer}, $bdata;
            $b->delete;
        }

        return $eos;
    }

    sub fetch_content_filter : FilterRequestHandler {
        my ($f, $bb)=@_;

        unless( $f->ctx ) {
            unless( $f->r->status==Apache2::Const::HTTP_OK ) {
                $f->remove;
                return Apache2::Const::DECLINED;
            }
            $f->ctx(1);
        }

        read_bb $bb, $f->r->pnotes->{out};

        return Apache2::Const::OK;
    }
}

{
    package Apache2::RequestRec;

    use Apache2::RequestRec ();
    use Apache2::SubRequest ();
    use Apache2::Const -compile=>qw/HTTP_OK/;

    sub safe_die {
        return $_[0]->output_filters->_safe_die($_[1]);
    }

    sub fetch_url {
        my ($I, $url)=@_;

        my $output=[];
        my $subr=$I->lookup_uri($url);
        if( $subr->status==Apache2::Const::HTTP_OK ) {
            $subr->pnotes->{out}=$output;
            $subr->add_output_filter
                (\&ModPerl2::Tools::Filter::fetch_content_filter);
            $subr->run;
        }
        return join('', @$output);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

ModPerl2::Tools - a few hopefully useful tools

=head1 SYNOPSIS

 use ModPerl2::Tools;

 ModPerl2::Tools::spawn +{keep_fd=>[3,4,7], survive=>1}, sub {...};
 ModPerl2::Tools::spawn +{keep_fd=>[3,4,7], survive=>1}, qw/bash -c .../;

 ModPerl2::Tools::safe_die $status;
 $r->safe_die($status);
 $f->safe_die($status);

 $content=ModPerl2::Tools::fetch_url $url;
 $content=$r->fetch_url($url);

=head1 DESCRIPTION

This module is a collection of functions and methods that I found useful
when working with C<mod_perl>. I work mostly under Linux. So, I don't expect
all of these functions to work on other operating systems.

=head2 Forking off long running processes

Sometimes one needs to spawn off a long running process as the result of
a request. Under modperl this is not as simple as calling C<fork>
because that way all open file descriptors would be inherited by the
child and, more subtle, the long running process would be killed when the
administrator shuts down the web server. The former is usually considered
a security issue, the latter a design decision.

There is already
L<< $r->spawn_proc_prog|Apache2::SubProcess/"spawn_proc_prog" >>
that serves a similar purpose as the C<spawn> function.
However, C<spawn_proc_prog> is not usable for long running processes
because it kills the children after a certain timeout.

=head3 Solution

 $pid=ModPerl2::Tools::spawn \%options, $subroutine, @parameters;

or

 $pid=ModPerl2::Tools::spawn \%options, @command_line;

C<spawn> expects as the first parameter an options hash reference.
The second parameter may be a code reference or a string.

In case of a code ref no other program is executed but the subroutine
is called instead. The remaining parameters are passed to this function.

Note, the perl environment under modperl differs in certain ways from
a normal perl environment. For example C<%ENV> is not bound to the C-level
C<environ>. These modifications are not undone by this module. So, it's
generally better to execute another perl interpreter instead of using
the C<$subroutine> feature.

The options parameter accepts these options:

=over 4

=item keep_fd =E<gt> \@fds

here an array of file descriptor numbers (not file handles) is expected.
All other file descriptors except for the listed and file descriptor 2
(STDERR) are closed before calling C<$subroutine> or executing
C<@command_line>.

=item survive =E<gt> $boolean

if passed C<false> the created process will be killed when Apache shuts down.
if true it will survive an Apache restart.

=back

The return code on success is the PID of the process. On failure C<undef>
or an empty string is returned.

The created process is not related as a child process to the current
apache child.

=head2 Serving C<ErrorDocument>s

Triggering C<ErrorDocument>s from a registry script or even more from an
output filter is not simple. The normal way as a handler is

  return Apache2::Const::STATUS;

This does not work for registry scripts. An output filter even if it
returns a status can trigger only a C<SERVER_ERROR>.

The main interface to enter standard error processing in Apache is
C<ap_die()> at C-level. Its Perl interface is hidden in L<Apache2::HookRun>.

There is one case when an error message cannot be sent to the user. This
happens if the HTTP headers are already on the wire. Then it is too late.

The various flavors of C<safe_die()> take this into account.

=over 4

=item ModPerl2::Tools::safe_die $status

This function is designed to be called from registry scripts. It
uses L<< Apache2::RequestUtil->request|Apache2::RequestUtil/"request" >>
to fetch the current request object. So,

 PerlOption +GlobalRequest

must be enabled.

Usage example:

 ModPerl2::Tools::safe_die 401;
 exit 0;

=item $r-E<gt>safe_die($status)

=item $f-E<gt>safe_die($status)

These 2 methods are to be used if a request object or a filter object
are available.

Usage from within a filter:

 package My::Filter;
 use strict;
 use warnings;

 use ModPerl2::Tools;
 use base 'Apache2::Filter';

 sub handler : FilterRequestHandler {
   my ($f, $bb)=@_;
   return $f->safe_die(410);
 }

The filter flavor removes the current filter from the request's output
filter chain.

=back

=head2 Fetching the content of another document

Sometimes a handler or a filter needs the content of another document
in the web server's realm. Apache provides subrequests for this purpose.

The 2 C<fetch_url> variants use a subrequest to fetch the content of another
document. The document can even be fetched via C<mod_proxy> from another
server. However, fetching a document directly as with L<LWP> for example
is not (yet) possible.

C<ModPerl2::Tools::fetch_url> needs

 PerlOption +GlobalRequest

Usage:

 $content=ModPerl2::Tools::fetch_url '/some/where?else=42';

 $content=$r->fetch_url('/some/where?else=42');

=head1 EXPORTS

None.

=head1 SEE ALSO

L<http://perl.apache.org>

=head1 AUTHOR

Torsten Förtsch, E<lt>torsten.foertsch@gmx.net<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Torsten Förtsch

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut

