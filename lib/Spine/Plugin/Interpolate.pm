# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Interpolate.pm,v 1.1.2.3.2.1 2007/10/02 22:01:36 phil Exp $

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
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.3.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Interpolate values in the Spine::Data structure a getval() time";

$MODULE = { author => 'websys@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {'PARSE/complete' => [ { name => 'interpolate',
                                              code => \&interpolate } ]
                     }
          };


sub interpolate
{
    my $c = shift;

    # Every user defined value is scanned for the existance of
    # <$var>.  If 'var' matches a defined key, the value of the
    # matching key is substituted for <$var>.
    foreach my $key (keys %{$c})
    {
        next if ($key =~ m/^c_/);

 	foreach my $value (@{$c->getvals($key)})
	{
            # Ooops.  Need to include digits in the regex for stuff like
            # 'lax1_num_instances' style keys
	    my $regex = '(?:<\$([\w_-]+)>)';
	    foreach my $match ( split(/$regex/, $value) )
            {
		next unless (exists $c->{$match});
		my $replace = $c->getval($match);
		$value =~ s/$regex/$replace/;
	    }
	}
    }

    return PLUGIN_SUCCESS;
}


1;
