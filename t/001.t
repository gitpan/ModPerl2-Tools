# -*- mode: cperl; cperl-indent-level: 4; cperl-continued-statement-offset: 4; indent-tabs-mode: nil -*-
use strict;
use warnings FATAL => 'all';

use Apache::Test qw{:withtestmore};
use Test::More;
use Apache::TestUtil;
use Apache::TestUtil qw/t_write_file t_client_log_error_is_expected
                        t_start_error_log_watch t_finish_error_log_watch/;
use Apache::TestRequest qw{GET_BODY GET};

#plan 'no_plan';
plan tests=>11;

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
