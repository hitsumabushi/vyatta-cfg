#!/usr/bin/perl
#
# Module: vyatta-interfaces.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# A copy of the GNU General Public License is available as
# `/usr/share/common-licenses/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at `http://www.gnu.org/copyleft/gpl.html'.
# You can also obtain it by writing to the Free Software Foundation,
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: November 2007
# Description: Script to assign addresses to interfaces.
# 
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";
use VyattaConfig;
use VyattaMisc;

use Getopt::Long;
use POSIX;
use NetAddr::IP;

use strict;
use warnings;

my $dhcp_daemon = '/sbin/dhclient';
my $dhclient_dir = '/var/lib/dhcp3/';


my ($eth_update, $eth_delete, $addr, $dev, $mac, $mac_update);

GetOptions("eth-addr-update=s" => \$eth_update,
	   "eth-addr-delete=s" => \$eth_delete,
	   "valid-addr=s"      => \$addr,
           "dev=s"             => \$dev,
	   "valid-mac=s"       => \$mac,
	   "set-mac=s"	       => \$mac_update,
);

if (defined $eth_update)       { update_eth_addrs($eth_update, $dev); }
if (defined $eth_delete)       { delete_eth_addrs($eth_delete, $dev);  }
if (defined $addr)             { is_valid_addr($addr, $dev); }
if (defined $mac)	       { is_valid_mac($mac, $dev); }
if (defined $mac_update)       { update_mac($mac_update, $dev); }

sub is_ip_configured {
    my ($intf, $ip) = @_;
    my $wc = `ip addr show $intf | grep $ip | wc -l`;
    if (defined $wc and $wc > 0) {
	return 1;
    } else {
	return 0;
    }
}

sub is_ip_duplicate {
    my ($intf, $ip) = @_;

    # 
    # get a list of all ipv4 and ipv6 addresses
    #
    my @ipaddrs = `ip addr show | grep inet | cut -d" " -f6`;
    chomp @ipaddrs;
    my %ipaddrs_hash = map { $_ => 1 } @ipaddrs;

    if (defined $ipaddrs_hash{$ip}) {
	#
	# allow dup if it's the same interface
	#
	if (is_ip_configured($intf, $ip)) {
	    return 0;
	}
	return 1;
    } else {
	return 0;
    }
}


sub dhcp_write_file {
    my ($file, $data) = @_;

    open(my $fh, '>', $file) || die "Couldn't open $file - $!";
    print $fh $data;
    close $fh;
}

sub dhcp_conf_header {
    my $output;

    my $date = `date`;
    chomp $date;
    $output  = "#\n# autogenerated by vyatta-interfaces.pl on $date\n#\n";
    $output .= "request subnet-mask, broadcast-address, time-offset, routers,\n";
    $output .= "\tdomain-name, domain-name-servers, host-name,\n";
    $output .= "\tinterface-mtu;\n\n";
    return $output;
}

sub is_dhcp_enabled {
    my $intf = shift;

    my $config = new VyattaConfig;

    if ($intf =~ m/^eth/) {
	if ($intf =~ m/(\w+)\.(\d+)/) {
	    $config->setLevel("interfaces ethernet $1 vif $2");
	} else {
	    $config->setLevel("interfaces ethernet $intf");
	}
    } elsif ($intf =~ m/^br/) {
	$config->setLevel("interfaces bridge $intf");
    } else {
	#
	# currently we only support dhcp on ethernet 
	# and bridge interfaces.
	#
	return 0;
    }
    my @addrs = $config->returnOrigValues("address");
    foreach my $addr (@addrs) {
	if (defined $addr && $addr eq "dhcp") {
	    return 1;
	}
    }
    return 0;
}

sub is_address_enabled {
    my $intf = shift;

    my $config = new VyattaConfig;
    
    if ($intf =~ m/^eth/) {
	if ($intf =~ m/(\w+)\.(\d+)/) {
	    $config->setLevel("interfaces ethernet $1 vif $2");
	} else {
	    $config->setLevel("interfaces ethernet $intf");
	}
    } elsif ($intf =~ m/^br/) {
	$config->setLevel("interfaces bridge $intf");
    } else {
	print "unsupported dhcp interface [$intf]\n";
	exit 1;
    }
    my @addrs = $config->returnOrigValues("address");
    foreach my $addr (@addrs) {
	if (defined $addr && $addr ne "dhcp") {
	    return 1;
	}
    }
    return 0;
}

sub get_hostname {
    my $config = new VyattaConfig;
    $config->setLevel("system");
    my $hostname = $config->returnValue("host-name");
    return $hostname;
}

sub dhcp_update_config {
    my ($conf_file, $intf) = @_;
    
    my $output = dhcp_conf_header();
    my $hostname = get_hostname();

    $output .= "interface \"$intf\" {\n";
    if (defined($hostname)) {
       $output .= "\tsend host-name \"$hostname\";\n";
    }
    $output .= "}\n\n";

    dhcp_write_file($conf_file, $output);
}

sub is_ip_v4_or_v6 {
    my $addr = shift;

    my $ip = NetAddr::IP->new($addr);
    if (defined $ip && $ip->version() == 4) {
	#
	# the call to IP->new() will accept 1.1 and consider
        # it to be 1.1.0.0, so add a check to force all
	# 4 octets to be defined
        #
	if ($addr !~ /\d+\.\d+\.\d+\.\d+/) {
	    return undef;
	}
	return 4;
    }
    $ip = NetAddr::IP->new6($addr);
    if (defined $ip && $ip->version() == 6) {
	return 6;
    }
    
    return undef;
}

sub generate_dhclient_intf_files {
    my $intf = shift;

    $intf =~ s/\./_/g;
    my $intf_config_file = $dhclient_dir . 'dhclient_' . $intf . '.conf';
    my $intf_process_id_file = $dhclient_dir . 'dhclient_' . $intf . '.pid';
    my $intf_leases_file = $dhclient_dir . 'dhclient_' . $intf . '.leases';
    return ($intf_config_file, $intf_process_id_file, $intf_leases_file);

}

sub run_dhclient {
    my $intf = shift;

    my ($intf_config_file, $intf_process_id_file, $intf_leases_file) = generate_dhclient_intf_files($intf);
    dhcp_update_config($intf_config_file, $intf);
    my $cmd = "$dhcp_daemon -q -nw -cf $intf_config_file -pf $intf_process_id_file  -lf $intf_leases_file $intf 2> /dev/null &";
    # adding & at the end to make the process into a daemon immediately
    system ($cmd);
}

sub stop_dhclient {
    my $intf = shift;

    my ($intf_config_file, $intf_process_id_file, $intf_leases_file) = generate_dhclient_intf_files($intf);
    my $cmd = "$dhcp_daemon -q -cf $intf_config_file -pf $intf_process_id_file -lf $intf_leases_file -r $intf 2> /dev/null";
    system ($cmd);
    system ("rm -f $intf_config_file");

}

sub update_eth_addrs {
    my ($addr, $intf) = @_;

    if ($addr eq "dhcp") {
	run_dhclient($intf);
	return;
    } 
    my $version = is_ip_v4_or_v6($addr);
    if (!defined $version) {
	exit 1;
    }
    if (is_ip_configured($intf, $addr)) {
	#
	# treat this as informational, don't fail
	#
	print "Address $addr already configured on $intf\n";
	exit 0;
    }

    if ($version == 4) {
	return system("ip addr add $addr broadcast + dev $intf");
    }
    if ($version == 6) {
	return system("ip -6 addr add $addr dev $intf");
    }
    print "Error: Invalid address/prefix [$addr] for interface $intf\n";
    exit 1;
}

sub if_nametoindex {
    my ($intf) = @_;

    open my $sysfs, "<", "/sys/class/net/$intf/ifindex" 
	|| die "Unknown interface $intf";
    my $ifindex = <$sysfs>;
    close($sysfs) or die "read sysfs error\n";
    chomp $ifindex;

    return $ifindex;
}

sub htonl {
    return unpack('L',pack('N',shift));
}

sub delete_eth_addrs {
    my ($addr, $intf) = @_;

    if ($addr eq "dhcp") {
	stop_dhclient($intf);
	system("rm -f /var/lib/dhcp3/dhclient_$intf\_lease");
	exit 0;
    } 
    my $version = is_ip_v4_or_v6($addr);
    if ($version == 6) {
	    exec 'ip', '-6', 'addr', 'del', $addr, 'dev', $intf
		or die "Could not exec ip?";
    }

    ($version == 4) or die "Bad ip version";

    if (is_ip_configured($intf, $addr)) {
	# Link is up, so just delete address
	# Zebra is watching for netlink events and will handle it
	exec 'ip', 'addr', 'del', $addr, 'dev', $intf
	    or die "Could not exec ip?";
    }
	
    exit 0;
}

sub update_mac {
    my ($mac, $intf) = @_;

    open my $fh, "<", "/sys/class/net/$intf/flags"
	or die "Error: $intf is not a network device\n";

    my $flags = <$fh>;
    chomp $flags;
    close $fh or die "Error: can't read state\n";

    if (POSIX::strtoul($flags) & 1) {
	# NB: Perl 5 system return value is bass-ackwards
	system "sudo ip link set $intf down"
	    and die "Could not set $intf down ($!)\n";
	system "sudo ip link set $intf address $mac"
	    and die "Could not set $intf address ($!)\n";
	system "sudo ip link set $intf up"
	    and die "Could not set $intf up ($!)\n";
    } else {
	exec "sudo ip link set $intf address $mac";
    }
    exit 0;
}
 
sub is_valid_mac {
    my ($mac, $intf) = @_;
    my @octets = split /:/, $mac;
    
    ($#octets == 5) or die "Error: wrong number of octets: $#octets\n";

    (($octets[0] & 1) == 0) or die "Error: $mac is a multicast address\n";

    my $sum = 0;
    $sum += strtoul('0x' . $_) foreach @octets;
    ( $sum != 0 ) or die "Error: zero is not a valid address\n";

    exit 0;
}

sub is_valid_addr {
    my ($addr_net, $intf) = @_;

    if ($addr_net eq "dhcp") { 
	if ($intf eq "lo") {
	    print "Error: can't use dhcp client on loopback interface\n";
	    exit 1;
	}
	if (is_dhcp_enabled($intf)) {
	    print "Error: dhcp already configured for $intf\n";
	    exit 1;
	}
	if (is_address_enabled($intf)) {
	    print "Error: remove static addresses before enabling dhcp for $intf\n";
	    exit 1;
	}
	exit 0; 
    }

    my ($addr, $net);
    if ($addr_net =~ m/^([0-9a-fA-F\.\:]+)\/(\d+)$/) {
	$addr = $1;
	$net  = $2;
    } else {
	exit 1;
    }

    my $version = is_ip_v4_or_v6($addr_net);
    if (!defined $version) {
	exit 1;
    }

    my $ip = NetAddr::IP->new($addr_net);
    my $network = $ip->network();
    my $bcast   = $ip->broadcast();
    
    if ($ip->version == 4 and $ip->masklen() == 31) {
       #
       # RFC3021 allows for /31 to treat both address as host addresses
       #
    } elsif ($ip->masklen() != $ip->bits()) {
       #
       # allow /32 for ivp4 and /128 for ipv6
       #
       if ($ip->addr() eq $network->addr()) {
          print "Can not assign network address as the IP address\n";
          exit 1;
       }
       if ($ip->addr() eq $bcast->addr()) {
          print "Can not assign broadcast address as the IP address\n";
          exit 1;
       }
    }

    if (is_dhcp_enabled($intf)) {
	print "Error: remove dhcp before adding static addresses for $intf\n";
	exit 1;
    }
    if (is_ip_duplicate($intf, $addr_net)) {
	print "Error: duplicate address/prefix [$addr_net]\n";
	exit 1;
    }

    if ($version == 4) {
	if ($net > 0 && $net <= 32) {
	    exit 0;
	}
    } 
    if ($version == 6) {
	if ($net > 1 && $net <= 128) {
	    exit 0;
	}
    }

    exit 1;
}

exit 0;

# end of file
