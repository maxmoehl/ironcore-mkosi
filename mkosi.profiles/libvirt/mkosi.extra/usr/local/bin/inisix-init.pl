#!/usr/bin/env perl

# This script waits for FRR to assign the routed default IP address to the
# loopback interface and uses it to calculate the prefix to use for inisix for
# it. The approach is quite brittle as it makes a number of assumptions which
# may not hold. The correct solution would be to rely on the information from
# the metadata service. Unfortunately this does no longer work once FRR is up as
# it will use the looback address to talk to the metadata service which only
# recognizes the DHCP addresses.

use strict;
use warnings;

use Socket qw(inet_pton inet_ntop AF_INET6);

sub primary_ip {
    open(my $fh, '-|', 'ip', '-6', '-br', 'address', 'show', 'dev', 'lo', 'scope', 'global')
        or die("cannot run ip: $!\n");
    my $out = do { local $/; <$fh> };

    close($fh)
        or die("ip exited with status $?\n");

    return $out =~ m{^\S+\s+\S+\s+([0-9a-fA-F:]+)/\d+}m ? $1 : undef;
}

my $ip;
until (defined($ip = primary_ip())) {
    sleep 1;
}

my $packed = inet_pton(AF_INET6, $ip)
    or die("invalid address: $ip\n");

substr($packed, 8) eq ("\x00" x 7) . "\x01"
    or die("lower 64 bits of $ip are not ::1\n");

my $base_prefix = inet_ntop(AF_INET6, substr($packed, 0, 8) . "\x00\x01" . ("\x00" x 6)) . "/80";

system("/usr/local/bin/inisix", "init", "prefix", $base_prefix, "96") == 0
    or die("inisix init prefix failed\n");
