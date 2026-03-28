#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 't';
use TestRebound;

ok(-x $REBOUND, 'rebound binary is executable');

subtest 'no arguments prints usage' => sub {
    my ($exit, $stderr) = run_rebound(args => []);
    is($exit, 1, 'exits 1');
    like($stderr, qr/Usage:/, 'prints usage');
};

subtest 'startup message logged' => sub {
    my ($exit, $stderr) = run_rebound(args => ['/bin/true']);
    like($stderr, qr/starting \/bin\/true/, 'logged startup with binary name');
};

subtest 'child exits 0 - rebound stops' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['/bin/true'],
        timeout => 3,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'exit code 0');
    unlike($stderr, qr/restarting/, 'did not restart');
};

subtest '-0 flag restarts on exit 0' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-0', '/bin/true'],
        timeout => 3,
    );
    ok(!$reaped || $exit != 0, 'rebound did not stop on exit 0');
    like($stderr, qr/restarting/, 'restarted at least once');
};

subtest '--restart-on-zero long option' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['--restart-on-zero', '/bin/true'],
        timeout => 3,
    );
    ok(!$reaped || $exit != 0, 'rebound did not stop on exit 0');
    like($stderr, qr/restarting/, 'restarted at least once');
};

subtest 'exit code propagation - child exits 42' => sub {
    my $script = make_script('exit 42');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => [$script],
        signal    => 'TERM',
        sig_delay => 0.5,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    like($stderr, qr/exited with status 42/, 'logged exit code 42');
    like($stderr, qr/restarting/, 'restarted (exit 42 triggers restart)');
};

subtest '-q suppresses all log output on normal exit' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['-q', '/bin/true'],
        timeout => 3,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'exit code 0');
    is($stderr, '', 'no output on stderr');
};

subtest '-q suppresses restart messages' => sub {
    my $script = make_script('exit 1');
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['-q', $script],
        signal    => 'TERM',
        sig_delay => 0.5,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    unlike($stderr, qr/restarting/, 'no restart message');
    unlike($stderr, qr/starting/, 'no startup message');
};

subtest '-q suppresses signal forwarding messages' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['-q', '/bin/sleep', '60'],
        signal    => 'TERM',
        sig_delay => 0.3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    is($stderr, '', 'no output on stderr');
};

subtest '--quiet long option works' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => ['--quiet', '/bin/true'],
        timeout => 3,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 0, 'exit code 0');
    is($stderr, '', 'no output on stderr');
};

subtest 'without -q messages are present' => sub {
    my ($exit, $stderr) = run_rebound(
        args    => ['/bin/true'],
        timeout => 3,
    );
    like($stderr, qr/starting/, 'startup message present without -q');
};

done_testing;
