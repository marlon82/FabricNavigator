#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use File::Temp qw(tempfile);
use Net::SSH2;

sub read_value {
    my $line = <STDIN>;
    return '' unless defined $line;
    chomp $line;
    return decode_base64($line);
}

my $host = read_value();
my $username = read_value();
my $password = read_value();
my $private_key = read_value();
my $passphrase = read_value();
my $port_line = <STDIN>;
chomp $port_line if defined $port_line;
my $port = defined($port_line) && $port_line =~ /^\d+$/ ? int($port_line) : 22;
exit 20 unless $host =~ /^(?:\d{1,3}\.){3}\d{1,3}$/ && length($username) && $port > 0 && $port < 65536;

my $ssh = Net::SSH2->new(timeout => 7000);
exit 21 unless $ssh && $ssh->connect($host, $port);
my $authenticated = 0;
if (length $password) {
    $authenticated = $ssh->auth(username => $username, password => $password) ? 1 : 0;
}
elsif (length $private_key) {
    my ($key_fh, $key_path) = tempfile('fabricnavigator-ssh-key-XXXXXX', TMPDIR => 1, UNLINK => 1);
    chmod 0600, $key_path;
    print {$key_fh} $private_key;
    close $key_fh;
    $authenticated = $ssh->auth(username => $username, privatekey => $key_path, passphrase => $passphrase) ? 1 : 0;
}
$ssh->disconnect('SSH probe complete') if $authenticated;
exit($authenticated ? 0 : 22);
