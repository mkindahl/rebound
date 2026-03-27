#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Time::HiRes qw(sleep);
use POSIX qw(:sys_wait_h);

use lib 't';
use TestRebound;

ok(-x $REBOUND, 'rebound binary is executable');

subtest 'SIGTERM forwarded - rebound exits' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['/bin/sleep', '60'],
        signal    => 'TERM',
        sig_delay => 0.3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    is($exit, 143, 'exit code 143 (128+SIGTERM)');
    like($stderr, qr/shutting down|exiting/, 'logged shutdown');
    unlike($stderr, qr/restarting/, 'did not restart');
};

subtest 'SIGINT forwarded - rebound exits' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['/bin/sleep', '60'],
        signal    => 'INT',
        sig_delay => 0.3,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    is($exit, 130, 'exit code 130 (128+SIGINT)');
    unlike($stderr, qr/restarting/, 'did not restart');
};

subtest 'child killed by SIGSEGV - restarts' => sub {
    my $script = make_script('kill -SEGV $$');
    my ($exit, $stderr) = run_rebound(
        args    => [$script],
        timeout => 3,
    );
    like($stderr, qr/killed by signal 11/, 'detected SIGSEGV');
    like($stderr, qr/restarting/, 'restarted after SIGSEGV');
};

subtest 'child killed by SIGKILL - restarts' => sub {
    my $script = make_script('kill -KILL $$');
    my ($exit, $stderr) = run_rebound(
        args    => [$script],
        timeout => 3,
    );
    like($stderr, qr/killed by signal 9/, 'detected SIGKILL');
    like($stderr, qr/restarting/, 'restarted after SIGKILL');
};

subtest 'child killed by SIGHUP - restarts' => sub {
    my $script = make_script('kill -HUP $$');
    my ($exit, $stderr) = run_rebound(
        args    => [$script],
        timeout => 3,
    );
    like($stderr, qr/killed by signal 1/, 'detected SIGHUP');
    like($stderr, qr/restarting/, 'restarted after SIGHUP');
};

subtest 'child killed by SIGTERM from within - rebound stops' => sub {
    my $script = make_script('kill -TERM $$');
    my ($exit, $stderr, $reaped) = run_rebound(
        args    => [$script],
        timeout => 3,
    );
    ok($reaped, 'rebound exited on its own');
    is($exit, 143, 'exit code 143');
    like($stderr, qr/terminated by signal 15/, 'logged SIGTERM termination');
    unlike($stderr, qr/restarting/, 'did not restart');
};

subtest 'SIGTERM during restart loop stops' => sub {
    my ($exit, $stderr, $reaped) = run_rebound(
        args      => ['/bin/false'],
        signal    => 'TERM',
        sig_delay => 0.5,
        timeout   => 5,
    );
    ok($reaped, 'rebound exited');
    like($stderr, qr/shutting down/, 'shut down after SIGTERM');
};

subtest 'SIGUSR1 forwarded to child' => sub {
    my $flagfile = "/tmp/rebound_test_usr1_$$";
    # Use a readiness flag so we know the trap is installed before signalling
    my $ready = "/tmp/rebound_test_ready_$$";
    my $script = make_script(<<"SH");
trap 'touch $flagfile; exit 0' USR1
touch $ready
while true; do sleep 0.1; done
SH

    unlink $flagfile;
    unlink $ready;
    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $err_fh;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>', $err_file or die;
        exec $REBOUND, $script;
        die "exec: $!";
    }

    # Wait for the child to signal readiness (trap installed)
    my $waited = 0;
    while ($waited < 3) {
        last if -f $ready;
        sleep 0.05;
        $waited += 0.05;
    }
    ok(-f $ready, 'child is ready (trap installed)');

    kill 'USR1', $pid;
    sleep 0.5;

    ok(-f $flagfile, 'child received SIGUSR1 (flag file created)');

    my $r = waitpid($pid, WNOHANG);
    if ($r <= 0) {
        kill 'TERM', $pid;
        waitpid($pid, 0);
    }
    unlink $flagfile;
    unlink $ready;
};

done_testing;
