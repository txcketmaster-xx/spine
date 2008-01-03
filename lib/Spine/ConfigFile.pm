# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

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

#
# A config file parser for Spine.  *NOT* part of configuration data tree.
# This parses Spine's own configuration file, primarily so that it can
# bootstrap itself enough to begin walking the configuration tree.
#

use strict;

package Spine::ConfigFile;
our ($VERSION, $ERROR, %ConfigKeys);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);

use IO::File;

sub new
{
    my $klass = shift;
    my %args  = @_;

    my $self  = bless { _filename => $args{Filename},
                        _keys     => $args{ConfigKeys},
                        _type     => $args{Type},
                        _parsed   => 0
                      }, $klass;

    if (not defined($self->{_keys})) {
        $self->{_keys} = \%ConfigKeys;
    }

    if (defined($self->{_filename})) {
        if (-f $self->{_filename} and -r $self->{_filename}) {
            if (defined($self->{_type})) {
                if ($self->{_type} eq 'Ini') {
                    if (not defined($self->parse_ini())) {
                        $self->error("Failed to parse $self->{_filename}.");
                        return undef;
                    }
                }
                else {
                    if (not $self->parse_config($self->{_keys})) {
                        $self->error("Failed to parse $self->{_filename}.");
                        return undef;
                    }
                }
            }
        }
        else { # File we were passed doesn't exist or isn't readable
            $self->error("$self->{_filename} doesn't exist or isn't readable");
            return undef;
        }
    }

    return $self;
}


sub error {
    my $self = shift;

    $ERROR .= join("\n", @_) . "\n";
}


sub parsed
{
    return shift->{_parsed};
}


sub parse_config
{
    my $self = shift;
    my ($config, @conf_keys, $keys_re);
    my ($fh, $i) = (undef, 1);

    if (ref($_[0]) eq 'HASH') {
        $config = shift;
        @conf_keys = keys(%{$config});
    }
    else {
        $config = {@_};
        @conf_keys = @_;
    }

    $keys_re = join('|', @conf_keys);

    if (not -r $self->{_filename}) {
	return undef;
    }

    $fh = new IO::File("< $self->{_filename}");
    if (not defined($fh)) {
	$self->error("Couldn't open \"$self->{_filename}\": $!\n");
        return undef;
    }

    while (<$fh>) {
	my $line = $_;
        chomp $line;

        if ($line =~ m/^\s*#/ or m/^\s*$/) {
            next;
        }

	if ($line =~ m/^[^=]+=[^=]*$/) {
	    if ($line =~ m/^($keys_re)=(.*)/) {
		if (ref($config->{$1}) eq 'ARRAY') {
		    push @{$config->{$1}}, $2;
		}
		else {
		    $config->{$1} = $2;
		}
	    }
	    else {
		$self->error("$self->{_filename}, line $i: ignoring " .
                             "unrecognized config key: $line");
	    }
	}
	$i++;
    }

    $fh->close();

    my ($k, $v);
    while (($k, $v) = each(%{$config})) {
        $self->{$k} = $v;
    }

    $self->{_parsed} = 1;
    return 1;
}


sub parse_ini
{
    my $self = shift;
    my ($fh, $i, $config, $section) = (undef, 1, {}, undef);

    if (not -f $self->{_filename}) {
	return undef;
    }

    if (not -r $self->{_filename}) {
	return undef;
    }

    $fh = new IO::File("< $self->{_filename}");
    if (not defined($fh)) {
	$self->error("Couldn't open \"$self->{_filename}\": $!\n");
        return undef;
    }

    while (<$fh>) {
	my $line = $_;
        chomp $line;

        if ($line =~ m/^\s*#/ or m/^\s*$/) {
            next;
        }

        # Section definition?
        if ($line =~ m/^\s*\[\s*(.*)\s*\]\s*$/) {
            $section = $1;

            if (exists($config->{$section})) {
                $self->error("Duplicate section header: $section");
                goto ini_error;
            }

            $config->{$section} = {};
            next;
        }

	if ($line =~ m/^\s*([^=\s]+)\s*=\s*(.*)\s*$/) {
            my ($key, $value) = ("$1", $2);

            if (exists($config->{$section}->{$key})) {
                $self->error("Duplicate entry in $self->{_filename}, line ".
                             $i . " [$section]: $key");
                goto ini_error;
            }

            $config->{$section}->{$key} = $value;
	}
	$i++;
    }

    $fh->close();

    my ($k, $v);
    while (($k, $v) = each(%{$config})) {
        $self->{$k} = $v;
    }

    $self->{_parsed} = 1;
    return 1;

 ini_error:
    $fh->close();
    $self->{_parsed} = 0;
    return undef;
}

1;
