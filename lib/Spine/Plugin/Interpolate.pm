# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Interpolate.pm,v 1.1.2.6.2.1 2007/09/11 21:28:00 rtilder Exp $

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

package Spine::Plugin::Interpolate;
use base qw(Spine::Plugin Exporter);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $INTERPOLATE_RE, @EXPORT_OK);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.6.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Interpolate values in the Spine::Data structure a getval() time";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {'PARSE/complete' => [ { name => 'interpolate',
                                              code => \&interpolate } ]
                     }
          };

@EXPORT_OK = qw(interpolate_value);

sub interpolate
{
    my $c = shift;

    $INTERPOLATE_RE = $c->getval_last('interpolate_regex');
    $INTERPOLATE_RE = '(?:<\$([\w_-]+)>)' unless ($INTERPOLATE_RE);
    $INTERPOLATE_RE = qr/$INTERPOLATE_RE/o;

    # Every user defined value is scanned for the existance of
    # <$var>.  If 'var' matches a defined key, the value of the
    # matching key is substituted for <$var>.
    foreach my $key (keys(%{$c}))
    {
        next if ($key =~ m/^c_/);

 	foreach my $value (@{$c->getvals($key)})
	{
            $value = _interpolate_value($c, $value);
	}
    }

    return PLUGIN_SUCCESS;
}


# Accessor to _interpolate_value
sub interpolate_value
{
    return _interpolate_value(@_);
}


sub _interpolate_value
{
    my ($c, $value) = @_;

    foreach my $match ( split(/$INTERPOLATE_RE/o, $value) )
    {
	next unless (exists($c->{$match}));
	my $replace = $c->getval($match);
	$value =~ s/$INTERPOLATE_RE/$replace/;
    }

    return $value;
}


1;
