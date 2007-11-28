#!/usr/bin/perl
# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Hardware.pm,v 1.1.2.3 2007/11/19 22:07:27 rtilder Exp $

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

use strict;

package Spine::Plugin::Hardware;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.3 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Hardware browser that wraps lshw";

$MODULE = { author => 'sedev@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'hardware_hunt',
                                                   code => \&hardware_hunt } ],
                     },
          };


use IO::Handle;
use IPC::Open3;
use XML::Simple;

=head1 NAME

Spine::Plugin::Hardware - A simple plugin to wrap lshw's output

=head1 SYNOPSIS

Basically just exec's lshw, parses the XML output, and massages the output a
bit.  Provides information out of the BIOS and one the various buses available
on the machine.

=cut


sub hardware_hunt
{
    my $c = shift;
    my $machine;

    # Run lshw
    my $xml = _exec_lshw($c, qw(/usr/sbin/lshw -quiet -xml));

    unless (defined($xml)) {
        # Some kind of error encountered, _exec_lshw() reports the errors
        return PLUGIN_FATAL;
    }

    # There's a small bug in certain versions of lshw's XML output that
    # causes some attributes' quotes to be escaped inadvertently.
    $xml =~ s/&quot;/"/g;

    (unef, $machine) = tidy(XMLin($xml,
                                  ForceArray => [ 'node',
                                                  'setting',
                                                  'capability',
                                                  'resource' ],
                                  ContentKey => '-content',
                                  KeyAttr => [ qw(id type) ],
                                  GroupTags => { 'capabilities'  => 'capability',
                                                 'configuration' => 'setting',
                                                 'resources' => 'resource' }));

    $c->set{c_hardware => new Spine::Plugin::Hardware::Accessor($machine));

    return PLUGIN_SUCCESS;
}


sub _exec_lshw
{
    my $c = shift;
    my @cmdline = @_;
    my $pid = -1;

    if (ref($_[0]) eq 'ARRAY')
    {
        # The plus sign is so that we actually call the shift function
        @cmdline = @{ +shift };
    }

    # Reset our fh handles
    my $stdin  = new IO::Handle();
    my $stdout = new IO::Handle();
    my $stderr = new IO::Handle();

    #
    # IPC::Open3::open3() is stupid.  If the filehandles you pass in are
    # IO::Handle objects and the command to run is passed in as an array,
    # it won't exec the command line properly.  However, if you join() it
    # head of time, it'll run just fine.  So broken.
    #
    # rtilder    Tue Apr 10 09:27:46 PDT 2007
    #
    my $cmdline = join(' ', @cmdline);
    $c->print(5, "Command line is: $cmdline");

    eval { $pid = open3($stdin, $stdout, $stderr, $cmdline) };

    if ($@)
    {
        $c->error("Some sort of exec'ing problem with lshw: $@", 'err');
        return undef;
    }

    # Siphon off output and error data so we can then waitpid() to reap
    # the child process
    $stdin->close();

    my @foo = $stdout->getlines();
    $stdout = [@foo];

    @foo = $stderr->getlines();
    $stderr = [@foo];

    my $rc = waitpid($pid, 0);

    if ($rc != $pid)
    {
        $c->error('lshw failed to run it seems', 'err');
        return undef;
    }

    # If there was an error, print it out
    if ($? >> 8 != 0) {
        $c->error("", 'err');
        return undef;
    }

    return wantarray ? @{$stdout} : join("\n", @{$stdout});
}


#
# As handy as XML::Simple is, it does have a few small issues with lshw's XML
# output
#
sub tidy
{
    my $obj = shift;
    my $changed = 0;

    foreach my $k (keys(%{$obj})) {
        my $v = $obj->{$k};

        if ($k eq 'node') {
            $obj->{subnodes} = delete($obj->{node});
            $k = 'subnodes';
        }

        if (ref($v) eq 'HASH') {
            my $num_keys = scalar(keys(%{$v}));

            # Empty hash?  Replace with undef
            if ($num_keys == 0) {
                $changed++;
                $obj->{$k} = undef;
            }
            # If our only key is named "content" or "value", eliminate the hash
            # ref
            elsif ($num_keys == 1) {
                foreach my $keyname (qw(content value)) {
                    if (exists($v->{$keyname})) {
                        $changed++;
                        $obj->{$k} = scrub_value($v->{$keyname})->[1];
                        last;
                    }
                }
            }
            # If it's still a hash ref, recurse
            if (ref($obj->{$k}) eq 'HASH') {
                my ($c, $val) = tidy($v);

                if ($c) {
                    $changed++;
                    $obj->{$k} = $val;
                }
            }
        }
        elsif (not ref($v)) {
            my ($c, $val) = scrub_value($v);

            if ($c) {
                $changed++;
                $obj->{$k} = $val;
            }
        }
    }

    return ($changed, $obj);
}


sub scrub_value
{
    my $v = shift;
    my $changed = 0;

    if ($v =~ m/^true$/io) {
        $changed++;
        $v = 1;
    }
    elsif ($v =~ m/^\d\+$/o) {
        $changed++;
        $v = int($v);
    }

    return wantarray ? ($changed, $v) : [$changed, $v];
}



#
# Data access.  The fun part
#

package Spine::Plugin::Hardware::Accessor;

=head1 NAME

Spine::Plugin::Hardware::Accessor - The runtime interface to lshw

=head1 SYNOPSIS

Provides the ability to query the hardware info discovered by lshw

=cut

our ($HARDWARE, $FLAT);

sub new
{
    my $klass = shift;

    $HARDWARE = shift;
    $FLAT     = _flatten($HARDWARE);

    return bless \'', $klass;
}


#
# Flatten the tree for ease of searching
#
sub _flatten
{
    my $tree = shift;

    my @flattened = ($tree);

    if (exists($tree->{subnodes})) {
        while (my ($k, $v) = each(%{$tree->{subnodes}})) {
            $v->{name}   = $k;
            $v->{parent} = $tree;
            push @flattened, _flatten($v);
        }
    }

    return wantarray ? @flattened : \@flattened;
}

=head1 BASIC QUERY INTERFACE

90% of the functionality is provided through a weak query system

=head2 find_items('field name' => 'criteria', ...)

find_items() will walk through the list arguments, comparing the name/value
pairs.  At the moment, only logical ANDing of all arguments is supported: a
"match" will be considered found only if all the criteria are met.

find_items() currently support three types of comparisons:

=item simple scalar

A string wise comparison will be performed on the values

=item regular expression

If the criteria is a reference to a regular expression object created via
qr//, then the expression will attempt to match.

=item code reference

If the criteria is a reference to a code block then the block will be executed
with the name and value of the field that is being compared passed in.

=head3

There is only specially handled field name("objects").  See below for its
meaning.

=item objects => [ ... list of objects to searc ... ]

If the objects keyword is provided it will be searched instead of the global
list of hardware information parsed from lshw.  This is usually 

=cut

sub find_items
{
    my $self  = shift;
    my %args = @_;

    my $objects = exists($args{objects}) ? delete($args{objects}) : $FLAT;

    my @fields = keys(%args);
    my @found;

    foreach my $node (@{$objects}) {
        my $matches = 0;

        foreach my $field (@fields) {
            if ($k eq $field) {
                my $param = $args{$field};
                my $ptype = ref($param);

                if ($ptype eq 'CODE'
                    and &{$args{$field}}($k, $v)) {
                    $matches++;
                }
                elsif (ref($ptype) eq 'RegExp'
                       and $v =~ /$param/) {
                elsif ($v eq $args{$field}) {
                    $matches++;
                }
            }
        }

        # We only support logical ANDing of values
        if ($matches == scalar(@fields)) {
            push @found, $obj;
        }
    }

    return wantarray ? @found : \@found;
}


=head1 CONVENIENCE QUERY FUNCTIONS

I've tried to anticipate the majority of the needs most people will have when
looking for specific hardware information.

=head2 Chassis information

=item B<uuid>

Returns the UUID string reported by the chassis's BIOS.

=cut

sub uuid
{
    return $HARDWARE->{configuration}->{uuid};
}


=item B<serial>

Returns the serial number reported by the chassis's BIOS.

=cut

sub serial
{
    return $HARDWARE->{configuration}->{serial};
}


=item B<physical_memory>

Returns the amount of physical memory in the machine as reported by the BIOS.
B<NOTE:> This does not necessarily correspond to the amount of memory the
running kernel can address.

=cut

sub physical_memory
{
    my $self = shift;

    my $total = 0;

    # I'm pretty sure that only one item should ever be returned but I'm not
    # sure how NUMA reports
    #
    # rtilder    Wed Oct  3 10:32:35 PDT 2007
    #
    foreach my $ram ($self->find_items(description => 'System Memory')) {
        $total += $ram->{size}->{content};
    }

    return $total;
}


=item B<num_dies>

Returns the number of CPU dies in the chassis.  B<NOTE:> This is not
necessarily equivalent to the number of cores!  For that, see num_cores()

=cut

sub num_dies
{
    my $self = shift;

    # SCSI and other buses can have host processors in the "processor" class.
    return scalar($self->find_items(class => 'processor',
                                    name => qr/^cpu:/));
}


=item B<num_cores>

Returns the number of processing cores(a.k.a. processors) in the chassis.

=cut

sub num_cores
{
    my $self = shift;

    my $cores = 0;

    # SCSI and other buses can have host processors in the "processor" class.
    my @dies =  $self->find_items(class => 'processor', name => qr/^cpu:/);

    foreach my $die (@dies) {
        if ($die->{product} =~ m/(?i:dual\s+core|duo)/o) {
            $core++;
        }
    }

    return $cores + scalar(@dies);
}


=item B<num_nics>

Returns the total number of physical network interfaces available as determined
by the bus scan.  Does not discriminate towards interfaces with link or driver
support at all.  This does B<NOT> include any kind of purely software defined
interfaces: i.e. bonded interfaces, alias interfaces, loopback interfaces,
etc.

=cut

sub num_nics
{
    return scalar(+shift->find_items(class => 'network'));
}


=item B<connected_nics>

Returns a list of the physical network interfaces that have link beat.

=cut

sub connected_nics
{
    my $self = shift;

    return $self->find_items(class => 'network',
                             configuration => sub { $_[1]->{link} eq 'yes'; });
}


=item B<supported_nics>

Returns a list of the physical network interfaces that have a driver loaded.

=cut

sub supported_nics
{
    my $self = shift;

    return $self->find_items(class => 'network',
                             configuration => sub { $_[1]->{driver} && 1; };
}


1;
