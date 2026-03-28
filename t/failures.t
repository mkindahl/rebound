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

subtest '-r limits total restarts' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-r', '3', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 1, 'exit code from last child');
    like($stderr, qr/max restarts \(3\) reached/, 'logged max restarts');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 3, 'restarted exactly 3 times');
};

subtest '-r 1 restarts once then stops' => sub {
    my $script = make_script('exit 42');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-r', '1', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 42, 'exit code 42 from child');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 1, 'restarted exactly once');
};

subtest '--max-restarts long option' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['--max-restarts', '2', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    like($stderr, qr/max restarts \(2\) reached/, 'logged max restarts');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 2, 'restarted exactly 2 times');
};

subtest '-r 0 means unlimited restarts' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['-r', '0', $script],
        signal    => 'TERM',
        sig_delay => 0.5,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited after SIGTERM');
    unlike($stderr, qr/max restarts/, 'no max restarts message');
    like($stderr, qr/restarting/, 'was restarting');
};

subtest '-d adds delay between restarts' => sub {
    my $counter = "/tmp/rebound_test_delay_$$";
    my $script = make_script(<<"SH");
COUNTER="$counter"
if [ ! -f "\$COUNTER" ]; then
    echo 1 > "\$COUNTER"
    date +%s.%N >> "\$COUNTER.times"
    exit 1
fi
COUNT=\$(cat "\$COUNTER")
if [ "\$COUNT" -lt 2 ]; then
    echo \$((COUNT + 1)) > "\$COUNTER"
    date +%s.%N >> "\$COUNTER.times"
    exit 1
fi
date +%s.%N >> "\$COUNTER.times"
rm -f "\$COUNTER"
exit 0
SH

    unlink $counter;
    unlink "$counter.times";
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-d', '0.5', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'final exit code 0');

    # Check that restarts were delayed
    if (open my $fh, '<', "$counter.times") {
        my @times = map { chomp; $_ } <$fh>;
        close $fh;
        if (@times >= 2) {
            my $gap = $times[1] - $times[0];
            cmp_ok($gap, '>=', 0.4, "restart gap >= 0.4s (got ${gap}s)");
        }
    }
    unlink $counter;
    unlink "$counter.times";
};

subtest '--restart-delay long option' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['--restart-delay', '0.2', '-r', '2', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    like($stderr, qr/max restarts/, 'hit max restarts');
};

subtest '-r and -d combined' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-r', '2', '-d', '0.3', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    like($stderr, qr/max restarts \(2\) reached/, 'hit max restarts');
    my @restarts = ($stderr =~ /restarting/g);
    is(scalar @restarts, 2, 'restarted exactly 2 times');
};

subtest '-b overrides default burst limit' => sub {
    # With -b 2, throttling should kick in after just 2 rapid failures
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['-b', '2', $script],
        signal    => 'TERM',
        sig_delay => 3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    like($stderr, qr/failing rapidly/, 'burst throttling triggered');
    # Count how many restarts before first "failing rapidly" message
    my @lines = split /\n/, $stderr;
    my $restarts_before_throttle = 0;
    for my $line (@lines) {
        last if $line =~ /failing rapidly/;
        $restarts_before_throttle++ if $line =~ /restarting/;
    }
    is($restarts_before_throttle, 2, 'throttled after 2 rapid failures');
};

subtest '--burst long option' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['--burst', '3', $script],
        signal    => 'TERM',
        sig_delay => 3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    like($stderr, qr/failing rapidly/, 'burst throttling triggered');
};

subtest '-b 0 disables burst throttling' => sub {
    # With -b 0 and -r 8, we should get 8 restarts with no throttle message
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-b', '0', '-r', '8', $script],
        timeout => 10,
    );
    ok($reaped, 'rebound exited on its own');
    unlike($stderr, qr/failing rapidly/, 'no burst throttling');
    like($stderr, qr/max restarts \(8\) reached/, 'hit max restarts');
};

subtest 'default burst limit is 5' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => [$script],
        signal    => 'TERM',
        sig_delay => 3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    like($stderr, qr/failing rapidly/, 'burst throttling triggered');
    my @lines = split /\n/, $stderr;
    my $restarts_before_throttle = 0;
    for my $line (@lines) {
        last if $line =~ /failing rapidly/;
        $restarts_before_throttle++ if $line =~ /restarting/;
    }
    is($restarts_before_throttle, 5, 'default throttle after 5 rapid failures');
};

done_testing;
