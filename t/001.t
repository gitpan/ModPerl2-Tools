# -*- mode: cperl; cperl-indent-level: 4; cperl-continued-statement-offset: 4; indent-tabs-mode: nil -*-
use strict;
use warnings FATAL => 'all';

use Apache::Test qw{:withtestmore};
use Test::More;
use Apache::TestUtil;
use Apache::TestUtil qw/t_write_file t_client_log_error_is_expected
                        t_start_error_log_watch t_finish_error_log_watch
                        t_mkdir t_catfile t_write_file/;
use Apache::TestRequest qw{GET_BODY GET};

#plan 'no_plan';
plan tests=>17;

Apache::TestRequest::user_agent(reset => 1,
				requests_redirectable => 0);

my $resp;

####################################################################
# spawn
####################################################################

t_client_log_error_is_expected;
t_start_error_log_watch;
$resp=GET_BODY('/spawn1');
ok grep(/TESTTESTTEST/, t_finish_error_log_watch),
   '/spawn1: STDERR still usable';
ok t_cmp $resp, qr/^\d+:\d+:\d+$/, '/spawn1';
my @pids=split /:/, $resp;
cmp_ok $pids[1], '!=', $pids[2], '/spawn1: PIDs differ';
cmp_ok $pids[0], '==', $pids[2], '/spawn1: spawn() return value';

t_client_log_error_is_expected;
t_start_error_log_watch;
$resp=GET_BODY('/spawn2');
ok grep(/TESTTESTTEST/, t_finish_error_log_watch),
   '/spawn2: STDERR still usable';
ok t_cmp $resp, qr/^\d+:\d+:\d+$/, '/spawn2';
@pids=split /:/, $resp;
cmp_ok $pids[1], '!=', $pids[2], '/spawn2: PIDs differ';
cmp_ok $pids[0], '==', $pids[2], '/spawn1: spawn() return value';

####################################################################
# fetch_url
####################################################################

$resp=GET_BODY('/data?10');
ok t_cmp $resp, (("x"x79)."\n")x10, '/data?10';

$resp=GET_BODY('/fetch1?10');
ok t_cmp $resp, 800, '/fetch1?10';

$resp=GET_BODY('/fetch1?1000');
ok t_cmp $resp, 80000, '/fetch1?1000';

SKIP: {
    no warnings qw/uninitialized numeric/;
    skip <<'XXX', 3 unless $ENV{TEST_PROXY};
If you want to test URL fetching via mod_proxy set the TEST_PROXY
environment variable to either 1 or an HTTP-URL that points to an
image/jpeg document. If you set TEST_PROXY=1 then
  http://foertsch.name/Regenbogen-ueber-Gaiberg-small.jpg
is fetched. There is no guarantee that this URL is always available.
XXX
    my $url='http://foertsch.name/Regenbogen-ueber-Gaiberg-small.jpg';
    $url=$ENV{TEST_PROXY} unless $ENV{TEST_PROXY}==1;
    $resp=GET_BODY('/fetch2?'.$url);
    my ($VAR1, $VAR2);
    eval "$resp";
    cmp_ok length $VAR1, '>', 0, 'got some data';
    cmp_ok $VAR2->{STATUS}, '==', 200, 'status==200';
    cmp_ok $VAR2->{'content-type'}, 'eq', 'image/jpeg',
           'content-type=image/jpeg';
}

t_start_error_log_watch;
$resp=GET_BODY('/fetch2?/does/not.exist');
ok !grep(/File does not exist/, t_finish_error_log_watch),
    'prevent "File does not exist" message in error_log';
{
    my ($VAR1, $VAR2);
    eval "$resp";
    cmp_ok $VAR2->{STATUS}, '==', 404, 'status==404';
}


SKIP: {
    skip 'mod_autoindex is needed to perform this test', 1
        unless need_module 'mod_autoindex.c';
    my $droot=Apache::Test::vars('documentroot');
    t_mkdir t_catfile $droot, 'dir';
    t_write_file t_catfile($droot, 'dir', '1.txt'), '1';
    t_write_file t_catfile($droot, 'dir', '2.txt'), '2';
    $resp=GET_BODY('/fetch2?/dir/');
    like $resp, qr/1\.txt/, 'fetch_url: directory listing';
}
