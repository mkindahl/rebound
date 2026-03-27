#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 't';
use TestRebound;

ok(-x $REBOUND, 'rebound binary is executable');

subtest 'child exits non-zero - rebound restarts then succeeds' => sub {
    my $counter = "/tmp/rebound_test_restart_$$";
    my $script = make_script(<<"SH");
COUNTER="$counter"
if [ ! -f "\$COUNTER" ]; then
    echo 1 > "\$COUNTER"
    exit 1
fi
COUNT=\$(cat "\$COUNTER")
if [ "\$COUNT" -lt 2 ]; then
    echo \$((COUNT + 1)) > "\$COUNTER"
    exit 1
fi
rm -f "\$COUNTER"
exit 0
SH

    unlink $counter;
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => [$script],
        timeout => 5,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'final exit code 0');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 2, 'restarted twice before success');
    unlink $counter;
};

subtest 'nonexistent binary - crash loop protection' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['/no/such/binary'],
        timeout => 10,
    );
    like($stderr, qr/exec.*No such file/, 'logged exec failure');
    like($stderr, qr/exited with status 127/, 'exit code 127 for missing binary');
    like($stderr, qr/failing rapidly/, 'crash loop protection triggered');
};

subtest 'rapid failures followed by recovery' => sub {
    # Fails 3 times quickly, then succeeds
    my $counter = "/tmp/rebound_test_rapid_$$";
    my $script = make_script(<<"SH");
COUNTER="$counter"
if [ ! -f "\$COUNTER" ]; then
    echo 1 > "\$COUNTER"
    exit 1
fi
COUNT=\$(cat "\$COUNTER")
if [ "\$COUNT" -lt 3 ]; then
    echo \$((COUNT + 1)) > "\$COUNTER"
    exit 1
fi
rm -f "\$COUNTER"
exit 0
SH

    unlink $counter;
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => [$script],
        timeout => 5,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'final exit code 0 after recovery');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 3, 'restarted 3 times');
    unlink $counter;
};

subtest 'different non-zero exit codes all trigger restart' => sub {
    for my $code (1, 2, 127, 255) {
        my $script = make_script("exit $code");
        my ($exit, $stderr) = run_rebound(
            args      => [$script],
            signal    => 'TERM',
            sig_delay => 0.3,
            timeout   => 5,
        );
        like($stderr, qr/exited with status $code/, "exit $code logged");
        like($stderr, qr/restarting/, "exit $code triggered restart");
    }
};

done_testing;
