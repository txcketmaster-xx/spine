# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: FilerExports.pm,v 1.1.2.4.2.1 2007/10/02 22:01:35 phil Exp $

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

package Spine::Plugin::FilerExports;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.4.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Uses the showmount command to present a list of available NFS mounts on the filer";

$MODULE = { author => 'websys@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'filer_exports',
                                               code => \&get_exports } ]
                     }
          };


sub get_exports
{
    my $c = shift;
    my $showmount_bin = $c->getval('showmount_bin');
    my $filers = $c->getvals('filers');
    my %mounts;
    my $DEBUG = $c->getval('filer_exports_plugin_debug');
    my $bu = $c->getval('c_bu');
    my $cluster = $c->getval('c_cluster');
    my $product = $c->getval('c_product');
    my $class = $c->getval('c_class');

    unless (-x $showmount_bin)
    {
	$c->error('showmount binary not found', 'err');
	return PLUGIN_FATAL;
    }

    if ($DEBUG)
    {
	$c->cprint('Filers are: ', join(' ', @{$filers}));
    }

    foreach my $filer (@{$filers})
    {
	if ($DEBUG)
	{
	    $c->cprint("Going through mounts on filer $filer");
	}

	for (`$showmount_bin -e $filer`)
	{
	    if ($DEBUG > 2)
	    {
		$c->cprint("    Processing output line: $_");
	    }

	    if ( m@/vol/([a-z0-9_]+)/ ([a-z0-9_]+)-([a-z0-9_]+)-
		 ([a-z0-9_]+)-([a-z0-9_]+)\s+.*@xi )
            {
 	        my %s = (
		    filer => $filer,	volume => $1,
		    bu => $2,		cluster => $3,
		    product => $4,	class => $5
   	        );

		if ($DEBUG > 3)
		{
		    $c->cprint("    Matches regex!");
		    $c->cprint("        volume  = $s{volume}");
		    $c->cprint("        bu      = $s{bu}");
		    $c->cprint("        cluster = $s{cluster}");
		    $c->cprint("        product = $s{product}");
		    $c->cprint("        class   = $s{class}");
		}

		if ( $s{bu} eq $bu &&
		     $s{cluster} eq $cluster &&
		     $s{product} eq $product )
		{
		    if ($DEBUG > 2)
		    {
			$c->cprint("    Adding to admin mounts.");
		    }

		    push(@{$mounts{admin}}, \%s);
		}
		elsif ($DEBUG > 2)
		{
		    $c->cprint("    Doesn't match admin mount requirements:");
		    $c->cprint('       c_bu      = ' . $bu);
		    $c->cprint('       c_cluster = ' . $cluster);
		    $c->cprint('       c_product = ' . $product);
		}

		if ( $s{bu} eq $bu &&
		     $s{cluster} eq $cluster &&
		     $s{product} eq $product &&
		     $s{class} eq $class )
		{
		    if ($DEBUG > 2)
		    {
			$c->cprint("    Adding to class specific mounts.");
		    }

		    push(@{$mounts{class}}, \%s);
		}
		elsif ($DEBUG > 2)
		{
		    $c->cprint("    Doesn't match class specificmount requirements:");
		    $c->cprint('       c_bu      = ' . $bu);
		    $c->cprint('       c_cluster = ' . $cluster);
		    $c->cprint('       c_product = ' . $product);
		    $c->cprint('       c_class = ' . $class);
		}


            }
	    elsif  (m@^/vol/(vol\d+)\s+.*$/@)
	    {
		# Very ugly hack to get only the filer short name.
		my ($filer_sn, undef) = split(/(\.|-)/, $filer);
		my %vol = (
		    filer => $filer,	volume => $1,
		    filer_short => $filer_sn
		);
		push(@{$mounts{volume}}, \%vol);
	    }
        }
    }

    $c->set('filer_mounts', \%mounts);
    return PLUGIN_SUCCESS;
}


1;
