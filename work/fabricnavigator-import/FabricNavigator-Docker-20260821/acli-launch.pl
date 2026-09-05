#!/usr/bin/perl
use strict;
use warnings;

my $component = '/opt/fabricnavigator/data/acli-component/current';
my $script = -f "$component/component.properties" && -f "$component/acli-terminal.pl"
    ? "$component/acli-terminal.pl"
    : '/opt/acli/acli-terminal.pl';

if ($script =~ m{^\Q$component\E/}) {
    $ENV{PERL5LIB} = length($ENV{PERL5LIB} || '')
        ? "$component:$ENV{PERL5LIB}"
        : $component;
}

exec '/usr/bin/perl', $script, @ARGV;
die "ACLI konnte nicht gestartet werden: $!\n";
