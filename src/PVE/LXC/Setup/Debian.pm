package PVE::LXC::Setup::Debian;

use strict;
use warnings;
use Data::Dumper;
use PVE::Tools qw($IPV6RE);
use PVE::LXC;
use File::Path;

use PVE::LXC::Setup::Base;

use base qw(PVE::LXC::Setup::Base);

sub new {
    my ($class, $conf, $rootdir) = @_;

    my $version = PVE::Tools::file_read_firstline("$rootdir/etc/debian_version");

    die "unable to read version info\n" if !defined($version);

    die "unable to parse version info\n"
	if $version !~ m/^(\d+(\.\d+)?)(\.\d+)?/;

    $version = $1;

    die "unsupported debian version '$version'\n" 
	if !($version >= 4 && $version < 9);

    my $self = { conf => $conf, rootdir => $rootdir, version => $version };

    $conf->{ostype} = "debian";

    return bless $self, $class;
}

sub setup_init {
    my ($self, $conf) = @_;

    my $filename = "/etc/inittab";
    return if !$self->ct_file_exists($filename);

    my $ttycount =  PVE::LXC::get_tty_count($conf);
    my $inittab = $self->ct_file_get_contents($filename);

    my @lines = grep {
	    # remove getty lines
	    !/^\s*\d+:\d+:[^:]*:.*getty/ &&
	    # remove power lines
	    !/^\s*p[fno0]:/
	} split(/\n/, $inittab);

    $inittab = join("\n", @lines) . "\n";

    $inittab .= "p0::powerfail:/sbin/init 0\n";

    my $version = $self->{version};
    my $levels = '2345';
    for my $id (1..$ttycount) {
	if ($version < 7) {
	    $inittab .= "$id:$levels:respawn:/sbin/getty -L 38400 tty$id\n";
	} else {
	    $inittab .= "$id:$levels:respawn:/sbin/getty --noclear 38400 tty$id\n";
	}
	$levels = '23';
    }

    $self->ct_file_set_contents($filename, $inittab);
}

sub setup_network {
    my ($self, $conf) = @_;

    my $networks = {};
    foreach my $k (keys %$conf) {
	next if $k !~ m/^net(\d+)$/;
	my $ind = $1;
	my $d = PVE::LXC::parse_lxc_network($conf->{$k});
	if ($d->{name}) {
	    my $net = {};
	    if (defined($d->{ip})) {
		if ($d->{ip} =~ /^(?:dhcp|manual)$/) {
		    $net->{address} = $d->{ip};
		} else {
		    my $ipinfo = PVE::LXC::parse_ipv4_cidr($d->{ip});
		    $net->{address} = $ipinfo->{address};
		    $net->{netmask} = $ipinfo->{netmask};
		}
	    }
	    if (defined($d->{'gw'})) {
		$net->{gateway} = $d->{'gw'};
	    }
	    if (defined($d->{ip6})) {
		if ($d->{ip6} =~ /^(?:auto|dhcp|manual)$/) {
		    $net->{address6} = $d->{ip6};
		} elsif ($d->{ip6} !~ /^($IPV6RE)\/(\d+)$/) {
		    die "unable to parse ipv6 address/prefix\n";
		} else {
		    $net->{address6} = $1;
		    $net->{netmask6} = $2;
		}
	    }
	    if (defined($d->{'gw6'})) {
		$net->{gateway6} = $d->{'gw6'};
	    }
	    $networks->{$d->{name}} = $net if keys %$net;
	}
    }

    return if !scalar(keys %$networks);

    my $filename = "/etc/network/interfaces";
    my $interfaces = "";

    my $section;

    my $done_v4_hash = {};
    my $done_v6_hash = {};
    
    my $print_section = sub {
	my ($new) = @_;
	
	return if !$section;

	my $net = $networks->{$section->{ifname}};

	if ($section->{type} eq 'ipv4') {
	    $done_v4_hash->{$section->{ifname}} = 1;

	    $interfaces .= "auto $section->{ifname}\n" if $new;

	    if ($net->{address} =~ /^(dhcp|manual)$/) {
		$interfaces .= "iface $section->{ifname} inet $1\n";
	    } elsif ($net->{address}) {
		$interfaces .= "iface $section->{ifname} inet static\n";
		$interfaces .= "\taddress $net->{address}\n" if defined($net->{address});
		$interfaces .= "\tnetmask $net->{netmask}\n" if defined($net->{netmask});
		$interfaces .= "\tgateway $net->{gateway}\n" if defined($net->{gateway});
		foreach my $attr (@{$section->{attr}}) {
		    $interfaces .= "\t$attr\n";
		}
	    }
	    
	    $interfaces .= "\n";
	    
	} elsif ($section->{type} eq 'ipv6') {
	    $done_v6_hash->{$section->{ifname}} = 1;
	    
	    if ($net->{address6} =~ /^(auto|dhcp|manual)$/) {
		$interfaces .= "iface $section->{ifname} inet6 $1\n";
	    } elsif ($net->{address6}) {
		$interfaces .= "iface $section->{ifname} inet6 static\n";
		$interfaces .= "\taddress $net->{address6}\n" if defined($net->{address6});
		$interfaces .= "\tnetmask $net->{netmask6}\n" if defined($net->{netmask6});
		$interfaces .= "\tgateway $net->{gateway6}\n" if defined($net->{gateway6});
		foreach my $attr (@{$section->{attr}}) {
		    $interfaces .= "\t$attr\n";
		}
	    }
	    
	    $interfaces .= "\n";	
	} else {
	    die "unknown section type '$section->{type}'";
	}

	$section = undef;
    };
	
    if (my $fh = $self->ct_open_file($filename, "r")) {
	while (defined (my $line = <$fh>)) {
	    chomp $line;
	    if ($line =~ m/^#/) {
		$interfaces .= "$line\n";
		next;
	    }
	    if ($line =~ m/^\s*$/) {
		if ($section) {
		    &$print_section();
		} else {
		    $interfaces .= "$line\n";
		}
		next;
	    }
	    if ($line =~ m/^\s*iface\s+(\S+)\s+inet\s+(\S+)\s*$/) {
		my $ifname = $1;
		&$print_section(); # print previous section
		if (!$networks->{$ifname}) {
		    $interfaces .= "$line\n";
		    next;
		}
		$section = { type => 'ipv4', ifname => $ifname, attr => []};
		next;
	    }
	    if ($line =~ m/^\s*iface\s+(\S+)\s+inet6\s+(\S+)\s*$/) {
		my $ifname = $1;
		&$print_section(); # print previous section
		if (!$networks->{$ifname}) {
		    $interfaces .= "$line\n";
		    next;
		}
		$section = { type => 'ipv6', ifname => $ifname, attr => []};
		next;
	    }
	    # Handle other section delimiters:
	    if ($line =~ m/^\s*(?:mapping\s
	                         |auto\s
	                         |allow-
	                         |source\s
	                         |source-directory\s
	                       )/x) {
	        &$print_section();
	        $interfaces .= "$line\n";
	        next;
	    }
	    if ($section && $line =~ m/^\s*((\S+)\s(.*))$/) {
		my ($adata, $aname) = ($1, $2);
		if ($aname eq 'address' || $aname eq 'netmask' ||
		    $aname eq 'gateway' || $aname eq 'broadcast') {
		    # skip
		} else {
		    push @{$section->{attr}}, $adata; 
		}
		next;
	    }
	    
	    $interfaces .= "$line\n";	    
	}
	&$print_section();
	
    }

    my $need_separator = 1;
    foreach my $ifname (sort keys %$networks) {
	my $net = $networks->{$ifname};
	
	if (!$done_v4_hash->{$ifname}) {
	    if ($need_separator) { $interfaces .= "\n"; $need_separator = 0; };	    
	    $section = { type => 'ipv4', ifname => $ifname, attr => []};
	    &$print_section(1);
	}
	if (!$done_v6_hash->{$ifname} && defined($net->{address6})) {
	    if ($need_separator) { $interfaces .= "\n"; $need_separator = 0; };	    
	    $section = { type => 'ipv6', ifname => $ifname, attr => []};
	    &$print_section(1);
	}
    }
    
    $self->ct_file_set_contents($filename, $interfaces);
}

1;
