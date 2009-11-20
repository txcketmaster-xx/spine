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

use strict;
use Carp;

package Spine::Plugin::PackageManager;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Registry;

our $DEBUG  = $ENV{SPINE_PACKAGEMANAGER_DEBUG} || 0;
our $CONF   = {};
our $DRYRUN = undef;
use constant PKGMGR_CONFKEY => 'pkgmgr_config';

our ( $VERSION, $DESCRIPTION, $MODULE );
our $PKGPLUGNAME = "Default";

$VERSION = sprintf( "%d.%02d", q$Revision: 1.1.2.2.2.1 $ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "Package Management Abstraction Layer";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        "PARSE/initialize" => [ { name => 'PackageManager Initialize',
                                  code => \&_initialize } ],
        "PARSE/complete" => [ { name => 'PackageManager',
                                code => \&_parse_complete, } ],
        APPLY => [ { name => 'PackageManager Apply',
                     code => \&_apply_changes } ],
        CLEAN => [ { name => 'PackageManager Clean',
                     code => \&_post_tidy } ],

             },
    cmdline => { _prefix => 'pkgmgr',
                 options => {}, }, };

# stores are used to pass package information between plugins.
# a store as a interface to searching for items
#    see... Spine::Plugin::PackageManager::Store bellow
sub get_store {
    return undef unless ( exists $CONF->{instance_cfg}->{ $_[0] }->{store} );
    return $CONF->{instance_cfg}->{ $_[0] }->{store};
}

# Runn all configured hooks that should run within PARSE/initialize
sub _initialize {
    my $c = shift;

    $DRYRUN = $c->getval('c_dryrun');
    my $registry = new Spine::Registry();

    $registry->create_hook_point(qw(PKGMGR/Config));

    return _run_section( $c, undef, 'PARSE/initialize' );
}

# run all configured hooks that run within the APPLY phase
sub _apply_changes {
    my $c  = shift;
    my $pc = $CONF;

    return _run_section( $c, $pc, 'APPLY' );

}

# run all configured hooks that run within the PARSE/complete phase
sub _parse_complete {
    my $c  = shift;
    my $pc = $CONF;

    my $registry = new Spine::Registry();

    $c->cprint( "Finding pkgmgr config", 4 );
    $CONF = $pc = $c->getval(PKGMGR_CONFKEY);

    $pc->{instance_cfg} = {};

    # If we have no instances ten nothing to do.
    my ( $pic, $point, $rc );
    unless ( defined $pc->{instances} ) {
        $c->cprint( 'No "instances" within (' . PKGMGR_CONFKEY . ') key', 2 );
        return PLUGIN_SUCCESS;
    }

    # Not sure if this is going to be useful... I guess it might be good
    # to tie templates to pkg info???
    $c->cprint( "Adding get_pkg_info data function", 3 );

    # TODO catch errors
    my $method = sub { new Spine::Plugin::PackageManager::DataHelper(@_) };
    unless ( $registry->install_method( "get_pkg_info", $method ) ) {
        return PLUGIN_ERROR;
    }

    # go through and load instance configs
    foreach my $instance ( @{ $pc->{instances} } ) {

        # We assume that there will be a key for the instance, but
        # fall back to a hash ref. XXX: This may be bad
        $pic = $pc->{instance_cfg}->{$instance} = $c->getval($instance) || {};

        $pic->{plugin_config} = {} unless exists $pic->{plugin_config};

        # use a store for package information.
        $pic->{store} = new Spine::Plugin::PackageManager::Store;

        # we keep dryrun in  the instance cfg since it can be placed
        # in the key by the user not just a global dry run.
        $pic->{dryrun} = 1 if ( defined $DRYRUN );
    }
    $pc->{loaded} = {};
    return _run_section( $c, $pc, 'PARSE/complete' );

}

# run all configured hooks that run within the CLEAN phase
sub _post_tidy {

    my $c  = shift;
    my $pc = $CONF;

    return _run_section( $c, $pc, 'CLEAN' );

}

# Will go through all packagemanager instances (normally only one)
# running any configured hooks for the phase passed along
sub _run_section {
    my ( $c, $pc, $phase ) = @_;

    # for every instance
    foreach my $instance ( @{ $pc->{instances} } ) {

        # Get the instance config
        my $pic = $pc->{instance_cfg}->{$instance};
        return PLUGIN_SUCCESS unless ( exists $pic->{Order}->{$phase} );

        my $registry = new Spine::Registry();

        # For every packagemanager section to run within this phase
        foreach ( @{ $pic->{Order}->{$phase} } ) {
            my ( $sec, @plugs ) = @{$_};

            # for every plugin within the pacakgemanager section
            foreach my $plugin (@plugs) {
                $c->cprint( "Starting $sec/$plugin", 3 );

                # Check if there is any instance config for the plugin, if not
                # then create the hash so that plugins always have at least a
                # blank hash.
                $pic->{plugin_config}->{$plugin} = {}
                  unless exists $pic->{plugin_config}->{$plugin};
                  
                my $point;

                # FIXME, this is horrid, need to implement a better design.
                #        We could define all the plugins within the spine config
                #        but that would be very messy looking...
                # For each plugin we have to run atempt to load the plugin
                # and register it's hook points.
                unless ( exists $pc->{loaded}->{"$sec/$plugin"} ) {
                    $pc->{loaded}->{"$sec/$plugin"} =
                      $registry->load_plugin("PackageManager::$plugin");
                    $point = $registry->get_hook_point("PKGMGR/$sec/$plugin");
                    $point->register_hooks("PackageManager::$plugin");
                } else {
                    $point = $registry->get_hook_point("PKGMGR/$sec/$plugin");
                }

                # Run all the hooks for this section/plugin (there is probably
                # only one)
                my $rc;
                ( undef, $rc ) =
                  $point->run_hooks_until( PLUGIN_STOP, $c, $pic, $instance,
                                           $pc );
                # Since the user has said they want it to run in the conifg
                # it is really bad if nothing implemented the hook point!
                if ( $rc != PLUGIN_FINAL ) {
                    $c->error( "Error running ($instance, $sec, $plugin)",
                               'crit' );
                    return PLUGIN_ERROR;
                }
            }
        }
    }
    return PLUGIN_SUCCESS;
}

1;

# small package to be used in things like overlay templates
package Spine::Plugin::PackageManager::DataHelper;
use strict;
use Spine::Plugin::PackageManager;

sub new {
    my ( $class, $c, $inst ) = @_;
    return undef unless ( defined $inst );
    my $self = bless {}, $class;
    $self->{store} = Spine::Plugin::PackageManager::get_store($inst);
    return undef unless defined( $self->{store} );
    return $self;
}

sub find {
    shift()->{store}->find_node(@_);
}

sub getval {
    shift()->{store}->get_node_val(@_);
}

1;

# TODO: Something should be made and called something like Spine::Store that
# is fast and good to replace this...
package Spine::Plugin::PackageManager::Store;
use strict;

# XXX This package is slow but it's interface can stay the same and the
# implementation reworked.... At least you can scan through for every use of it
# and rework even if the api changes.
# TODO: create a per store index for keys like 'name' or add a 'add_index' func.

# nodes that are returned are currently [ <store ref>, <node ref> ] this is to
# be faster then returning a real object while being able to delete a node
# without having to scan every store.

sub new {
    my ( $class, $pkg ) = @_;

    return bless { store => {}, }, $class;
}

# create a node in a store
sub create_node {
    my $self = shift;
    my ( $store, @args ) = @_;

    $self->{store}->{$store} = [] unless exists $self->{store}->{$store};
    my $node = {};
    push @{ $self->{store}->{$store} }, $node;
    $node = [ $self->{store}->{$store}, $node ];
    $self->set_node_val( $node, @args );
    return $node;
}

# add a node to a store, only to be used after a remove_node call
sub add_node {
    my $self = shift;
    my ( $store, $node, @args ) = @_;
    if ( defined $node->[0] ) {

        # we don't allow nodes to be in two places
        return undef;
    }
    $self->{store}->{$store} = [] unless exists $self->{store}->{$store};
    push @{ $self->{store}->{$store} }, $node;
    $node = [ $self->{store}->{$store}, $node ];
    $self->set_node_val( $node, @args );
    return $node;
}

# Find either all nodes in a store,
# or all nodes in a <store> with a <key>
# or all nodes in a <store> with a <key> of <value> ... <key> <value>
# values of undef are take to mean as long as the key exists.
sub find_node {
    my $self = shift;
    my ( $store, @where ) = @_;

    return undef unless ( exists $self->{store}->{$store} );

    my ( @result, $key, $value, $node );
  NODE: foreach $node ( @{ $self->{store}->{$store} } ) {
        for ( my $i = 0 ; $i < $#where ; $i = $i + 2 ) {
            $key   = $where[$i];
            $value = $where[ $i + 1 ];
            unless ( exists $node->{$key}
                     && ( !defined $value || $node->{$key} eq $value ) )
            {
                next NODE;
            }
        }
        push @result, [ $self->{store}->{$store}, $node ];
    }

    return wantarray ? @result : ( exists $result[0] ? $result[0] : undef );
}

# list the current store names
sub list_stores {
    my $self = shift;
    return keys %{ $self->{store} };
}

# remove a node, return the unconnected node so that
# it can be used by add_node if wanted...
sub remove_node {
    my $self = shift;
    my (@nodes) = @_;

    my @result;
  NODE: foreach my $node (@nodes) {

        # since find_node can return undef it's worth checking.
        next unless defined $node;
        for ( my $i = 0 ; $i < @{ $node->[0] } ; $i++ ) {
            if ( $node->[1] == $node->[0]->[$i] ) {
                splice( @{ $node->[0] }, $i );
                push @result, [ undef, $node->[1] ];
                next NODE;
            }
        }
        push @result, undef;
    }
    return wantarray ? @result : $result[0];
}

# FIXME: should this be a deep copy?
# shallow copy of a node to another
sub copy_node {
    my $self = shift;
    my ( $src, $dst ) = @_;
    return %{ $dst->[1] } = %{ $src->[1] };
}

# set one or move value of a node
sub set_node_val {
    my $self = shift;
    my ( $node, @data ) = @_;

    # since find_node can return undef it's worth checking.
    return 0 unless defined $node;

    my ( $key, $value );
    while ( $key = shift @data ) {
        my $value = shift @data;
        $node->[1]->{$key} = $value;
    }
    return 1;
}

# Will either take a key name or a array ref of key names and
# return either a key value or array ref of key values. If more then
# one node is passed it returns an array of these items
# XXX: key is the first arg
sub get_node_val {
    my $self = shift;
    my ( $key, @nodes ) = @_;
    my @result;
    my $node;
    foreach $node (@nodes) {

        # since find_node can return undef it's worth checking.
        next unless defined $node;
        if ( ref($key) ) {
            my @sub_result;
            foreach (@$key) {
                push @sub_result, $node->[1]->{$_};
            }
            push @result, \@sub_result;
        } else {
            push @result, $node->[1]->{$key};
        }
    }
    return wantarray ? @result : $result[0];
}

1;
