# cgroup handler
#
# This package should deal with figuring out the right cgroup path for a
# container (via the command socket), reading and writing cgroup values, and
# handling cgroup v1 & v2 differences.
#
# Note that the long term plan is to have resource manage functions intead of
# dealing with cgroup files on the outside.

package PVE::LXC::CGroup;

use strict;
use warnings;

use POSIX qw();

use PVE::Tools qw(
    file_get_contents
    file_read_firstline
);

use PVE::LXC::Command;

# We don't want to do a command socket round trip for every cgroup read/write,
# so any cgroup function needs to have the container's path cached, so this
# package has to be instantiated.
#
# LXC keeps separate paths by controller (although they're normally all the
# same, in our # case anyway), so we cache them by controller as well.
sub new {
    my ($class, $vmid) = @_;

    my $self = { vmid => $vmid };

    return bless $self, $class;
}

my $CPUSET_BASE = undef;
# Find the cpuset cgroup controller.
#
# This is a function, not a method!
sub cpuset_controller_path() {
    if (!defined($CPUSET_BASE)) {
	my $CPUSET_PATHS = [
	    # legacy cpuset cgroup:
	    ['/sys/fs/cgroup/cpuset',  'cpuset.effective_cpus'],
	    # pure cgroupv2 environment:
	    ['/sys/fs/cgroup',         'cpuset.cpus.effective'],
	    # hybrid, with cpuset moved to cgroupv2
	    ['/sys/fs/cgroup/unified', 'cpuset.cpus.effective'],
	];

	my ($result) = grep { -f "$_->[0]/$_->[1]" } @$CPUSET_PATHS;
	die "failed to find cpuset controller\n" if !defined($result);

	$CPUSET_BASE = $result->[0];
    }

    return $CPUSET_BASE;
}

my $CGROUP_MODE = undef;
# Figure out which cgroup mode we're operating under:
#
# Returns 1 if cgroupv1 controllers exist (hybrid or legacy mode), and 2 in a
# cgroupv2-only environment.
#
# This is a function, not a method!
sub cgroup_mode() {
    if (!defined($CGROUP_MODE)) {
	my ($v1, $v2) = PVE::LXC::get_cgroup_subsystems();
	if (keys %$v1) {
	    # hybrid or legacy mode
	    $CGROUP_MODE = 1;
	} elsif ($v2) {
	    $CGROUP_MODE = 2;
	}
    }

    die "unknown cgroup mode\n" if !defined($CGROUP_MODE);
    return $CGROUP_MODE;
}

# Get a subdirectory (without the cgroup mount point) for a controller.
#
# If `$controller` is `undef`, get the unified (cgroupv2) path.
#
# Note that in cgroup v2, lxc uses the activated controller names
# (`cgroup.controllers` file) as list of controllers for the unified hierarchy,
# so this returns a result when a `controller` is provided even when using
# a pure cgroupv2 setup.
my sub get_subdir {
    my ($self, $controller, $limiting) = @_;

    my $entry_name = $controller || 'unified';
    my $entry = ($self->{controllers}->{$entry_name} //= {});

    my $kind = $limiting ? 'limit' : 'ns';
    my $path = $entry->{$kind};

    return $path if defined $path;

    $path = PVE::LXC::Command::get_cgroup_path(
	$self->{vmid},
	$controller,
	$limiting,
    ) or return undef;

    # untaint:
    if ($path =~ /\.\./) {
	die "lxc returned suspicious path: '$path'\n";
    }
    ($path) = ($path =~ /^(.*)$/s);

    $entry->{$kind} = $path;

    return $path;
}

# Get a path for a controller.
#
# `$controller` may be `undef`, see get_subdir above for details.
sub get_path {
    my ($self, $controller) = @_;

    my $path = get_subdir($self, $controller)
	or return undef;

    # The main mount point we currenlty assume to be in a standard location.
    return "/sys/fs/cgroup/$path" if cgroup_mode() == 2;
    return "/sys/fs/cgroup/unified/$path" if !defined($controller);
    return "/sys/fs/cgroup/$controller/$path";
}

# Parse a 'Nested keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_nested_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	my ($key, @values) = split(/\s+/, $line);

	my $d = ($res->{$key} = {});

	foreach my $value (@values) {
	    if (my ($key, $value) = ($value =~ /^([^=]+)=(.*)$/)) {
		$d->{$key} = $value;
	    } else {
		warn "bad key=value pair in nested keyed file\n";
	    }
	}
    }
    return $res;
}

# Parse a 'Flat keyed' file:
#
# See kernel documentation `admin-guide/cgroup-v2.rst` 4.1.
my sub parse_flat_keyed_file($) {
    my ($data) = @_;
    my $res = {};
    foreach my $line (split(/\n/, $data)) {
	if (my ($key, $value) = ($line =~ /^(\S+)\s+(.*)$/)) {
	    $res->{$key} = $value;
	} else {
	    warn "bad 'key value' pair in flat keyed file\n";
	}
    }
    return $res;
}

# Parse out 'diskread' and 'diskwrite' values from I/O stats for this container.
sub get_io_stats {
    my ($self) = @_;

    my $res = {
	diskread => 0,
	diskwrite => 0,
    };

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('io'))) {
	    # cgroupv2 environment, io controller enabled
	    my $io_stat = file_get_contents("$path/io.stat");

	    my $data = parse_nested_keyed_file($io_stat);
	    foreach my $dev (keys %$data) {
		my $dev = $data->{$dev};
		if (my $b = $dev->{rbytes}) {
		    $res->{diskread} += $b;
		}
		if (my $b = $dev->{wbytes}) {
		    $res->{diskread} += $b;
		}
	    }
	} else {
	    # io controller not enabled or container not running
	    return undef;
	}
    } elsif (defined(my $path = $self->get_path('blkio'))) {
	# cgroupv1 environment:
	my $io = file_get_contents("$path/blkio.throttle.io_service_bytes_recursive");
	foreach my $line (split(/\n/, $io)) {
	    if (my ($type, $bytes) = ($line =~ /^\d+:\d+\s+(Read|Write)\s+(\d+)$/)) {
		$res->{diskread} += $bytes if $type eq 'Read';
		$res->{diskwrite} += $bytes if $type eq 'Write';
	    }
	}
    } else {
	# container not running
	return undef;
    }

    return $res;
}

# Read utime and stime for this container from the cpuacct cgroup.
# Values are in milliseconds!
sub get_cpu_stat {
    my ($self) = @_;

    my $res = {
	utime => 0,
	stime => 0,
    };

    if (cgroup_mode() == 2) {
	if (defined(my $path = $self->get_path('cpu'))) {
	    my $data = eval { file_get_contents("$path/cpu.stat") };

	    # or no io controller available:
	    return undef if !defined($data);

	    $data = parse_flat_keyed_file($data);
	    $res->{utime} = int($data->{user_usec} / 1000);
	    $res->{stime} = int($data->{system_usec} / 1000);
	} else {
	    # memory controller not enabled or container not running
	    return undef;
	}
    } elsif (defined(my $path = $self->get_path('cpuacct'))) {
	# cgroupv1 environment:
	my $clock_ticks = POSIX::sysconf(&POSIX::_SC_CLK_TCK);
	my $clk_to_usec = 1000 / $clock_ticks;

	my $data = parse_flat_keyed_file(file_get_contents("$path/cpuacct.stat"));
	$res->{utime} = int($data->{user} * $clk_to_usec);
	$res->{stime} = int($data->{system} * $clk_to_usec);
    } else {
	# container most likely isn't running
	return undef;
    }

    return $res;
}

1;
