package TestRebound;
use strict;
use warnings;
use POSIX qw(:sys_wait_h);
use File::Temp qw(tempfile);
use Time::HiRes qw(time sleep);
use Exporter 'import';

our @EXPORT = qw(run_rebound make_script $REBOUND);

our $REBOUND = $ENV{REBOUND} || './rebound';

# Run rebound with a timeout, capture stderr, return (exit_code, stderr, reaped)
sub run_rebound {
    my (%opts) = @_;
    my $args      = $opts{args}      // [];
    my $timeout   = $opts{timeout}   // 5;
    my $signal    = $opts{signal};
    my $sig_delay = $opts{sig_delay} // 0.3;

    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $err_fh;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>', $err_file or die "open: $!";
        exec $REBOUND, @$args;
        die "exec: $!";
    }

    if ($signal) {
        sleep $sig_delay;
        kill $signal, $pid;
    }

    my $reaped = 0;
    my $status;
    my $start = time();
    while (time() - $start < $timeout) {
        my $r = waitpid($pid, WNOHANG);
        if ($r > 0) {
            $status = $?;
            $reaped = 1;
            last;
        }
        sleep 0.05;
    }

    unless ($reaped) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $status = $?;
    }

    open my $fh, '<', $err_file or die "open: $!";
    my $stderr = do { local $/; <$fh> };
    close $fh;

    my $exit_code;
    if (WIFEXITED($status)) {
        $exit_code = WEXITSTATUS($status);
    } elsif (WIFSIGNALED($status)) {
        $exit_code = 128 + WTERMSIG($status);
    }

    return ($exit_code, $stderr, $reaped);
}

# Create a temporary executable shell script
sub make_script {
    my ($code) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.sh', UNLINK => 1);
    print $fh "#!/bin/sh\n$code\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

1;
