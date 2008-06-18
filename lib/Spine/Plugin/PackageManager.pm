# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm,v 1.1.2.2.2.1 2007/10/02 22:01:36 phil Exp $

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


our $DEBUG = $ENV{SPINE_PACKAGEMANAGER_DEBUG} || 0;
our $CONF = {};
our $DRYRUN = undef;
use constant  PKGMGR_CONFKEY => 'pkgmgr_config';


our ($VERSION, $DESCRIPTION, $MODULE);
our $PKGPLUGNAME = "Default";

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.2.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Package Management Abstraction Layer";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 
                       "PARSE/initialize"    => [ { name => 'PackageManager Initialize',
                                                    code => \&initialize } ],
                       "PARSE/complete"      => [ { name => 'PackageManager Configure',
                                                    code => \&load_config, } ],
                       APPLY                 => [ { name => 'PackageManager',
                                                    code => \&apply_changes } ],
                       CLEAN                 => [ { name => 'PackageManager Clean',
                                                    code => \&post_tidy } ],
                       "PKGMGR/CalcMissing"  => [ { name => 'PackageManager CalcMissing',
                                                    code => \&calc_missing } ],
                       "PKGMGR/CalcRemove"   => [ { name => 'PackageManager CalcRemove',
                                                    code => \&calc_remove } ],
                       "PKGMGR/Report"       => [ { name => 'PackageManager Report',
                                                    code => \&report } ],
                       "PKGMGR/ResolveInstalled" => [ { name => 'PackageManager ResolveInstaled',
                                                        code => \&resolve_deps } ],

                     },
            cmdline => { _prefix => 'pkgmgr',
                         options => { },
                       },
          };

sub get_store {
    return undef unless (exists $CONF->{instance_cfg}->{$_[0]}->{store});
    return $CONF->{instance_cfg}->{$_[0]}->{store};
}

sub initialize {
    my $c = shift;
    
    $DRYRUN = $c->getval('c_dryrun');
    my $registry = new Spine::Registry();

    $registry->create_hook_point(qw(PKGMGR/Config));

    # Create the default hook points for package management plugins
    # A plugin may chose to add it's own as needed... This is just
    # to try to keep plugins being readable...
    # Init => Initialization steps
    # Update => Run automatic updates
    # Lookup => Build list of installed packages
    # Diff => Build out Remove and Install lists
    # CheckMissing => Will check if the missing packages are available
    #                 may well have to check for 'provides' and manipulate
    # ResolveInstalled => Look up deps for installed packages that will stay
    # ResolveMissing => Look up deps for to be installed packages
    # Report => Will report what is intended
    # Retrieve => Retrieve packages
    # Install => Install packages
    # Remove => Remove packages
    # Validate => Reports what got done
    $registry->create_hook_point(qw(PKGMGR/Init
                                    PKGMGR/Update
                                    PKGMGR/CheckUpdates
                                    PKGMGR/Lookup
                                    PKGMGR/CalcMissing
                                    PKGMGR/CalcRemove
                                    PKGMGR/ResolveInstalled
                                    PKGMGR/ResolveMissing
                                    PKGMGR/Report
                                    PKGMGR/Retrieve
                                    PKGMGR/Install
                                    PKGMGR/Remove
                                    PKGMGR/Validate));


    return PLUGIN_SUCCESS;
}

# Start of real work, for each instance and it's config
# we start the apply section for that instance.
sub apply_changes {
    my $c = shift;
    my $pc = $CONF;
    my $rc = 0;
    my $point;


    $c->cprint("Starting");

    # Used to store anything that we might need
    # between hooks but don't want for later
    my $work = {};

    while (my ($instance, $pic)  = each %{$pc->{instance_cfg}}) {
        # Create the work area for the instance
        # things that don't happen here will stay
        # in the data tree...
        $work->{$instance} = {} unless (exists $work->{$instance});
        process_instance($c, $pc, $pic, $work->{$instance});
    }
}


# Load the Package Manager config then load instance configs
sub load_config {
    my $c = shift;
    my $pc = $CONF;

    my $registry = new Spine::Registry();

    $c->cprint("Finding pkgmgr config", 4);
    $CONF = $pc = $c->getval(PKGMGR_CONFKEY);
                  
    $pc->{instance_cfg} = { };

    # If we have no instances ten nothing to do.
    my ($pic, $point, $rc);
    unless (defined $pc->{instances}) {
        $c->cprint('No "instances" within ('.PKGMGR_CONFKEY.') key', 2);
        return PLUGIN_SUCCESS;
    }
    $c->cprint("Adding get_pkg_info data function", 2);
    # TODO catch errors
    my $method = sub { new Spine::Plugin::PackageManager::DataHelper(@_) };
    unless ($registry->install_method("get_pkg_info", $method)) {
        return PLUGIN_ERROR;
    }

    # go through and load instance configs
    foreach my $instance (@{$pc->{instances}}) {
        # We assume that there will be a key for the instance, but
        # fall back to a hash ref. XXX: This may be bad
        $pic = $pc->{instance_cfg}->{$instance} = $c->getval($instance) || {};
        # use a store for package information.
        $pic->{store} = new Spine::Plugin::PackageManager::Store;
        # we keep dryrun in  the instance cfg since it can be placed
        # in the key by the user not just a global dry run.
        $pic->{dryrun} = 1 if (defined $DRYRUN);
        # Take the instance conf and pass it through the config plugins
        # hopeful something will pick it up.
        $c->cprint("Finding config plugin for ($instance)", 4);
        $point = $registry->get_hook_point("PKGMGR/Config");
        # PKGINFO is passed to allow plugins to add functions
        $rc = $point->run_hooks_until(PLUGIN_STOP, $c, $pic, $instance, $pc);
        if ($rc != PLUGIN_FINAL) {
            # Nothing implemented config for this instance...
            $c->error("Error with config for ($instance)", 'crit');
            return PLUGIN_ERROR;
        }
    }
}

sub process_instance {
    my $c = shift;
    my $pc = shift;
    my $pic = shift;
    my $work = shift;

    # IF we have not got a hook order for the instance
    # use the default one
    unless (exists $pic->{order}) {
        $pic->{order} = $pc->{default_order};
    }

    my $registry = new Spine::Registry();

    # Go through the order calling the hooks
    my ($point, $rc);
    foreach my $section (@{$pic->{order}}) {
        # XXX: each section can be in a few forms this might be confusing
        #      what ever it is we want an array ref in the end
        # 1. A hash ref, it will only have one key which is the section name
        if (ref($section) eq 'HASH') {
            $section = [ each %$section ];
        # 3. it's a scalar
        } elsif (ref($section)) {
            $section = [ $section ];
        } else {
            $c->error("Error parsing section order config", 'crit');
            return PLUGIN_ERROR;
        }
        # Now we want the second element of our array ref to be a hash ref
        # of implementers... but it can start as
        # 1. there is no second part so we assume default
        if (!exists $section->[1]) {
            push @{$section}, { Default => undef };
        # 2. an array ref
        } elsif (ref($section->[1]) eq 'ARRAY') {
            my %tmp_hash = map { $_ => undef } @{$section->[1]};
            $section->[1] = \%tmp_hash;
        # 2. a scalar
        } elsif (!ref($section->[1])) {
            $section->[1] = { $section->[1] => undef }
        } else {
            $c->error("Error in section order ($section->[0]), invalid config", 'crit');
            return PLUGIN_ERROR;
        }

        # Now $section is an array ref of the secname and a hash ref of implementers
        # i.e. [ "Init", { YUM => undef, APT => undef } ]

        # HOOKME PKGMGR/<SECTION>
        $c->cprint("Starting section ($section->[0])", 2);
        $point = $registry->get_hook_point("PKGMGR/$section->[0]");
        $rc = $point->run_hooks_until(PLUGIN_STOP, $c, $pic, $work, $section->[1]);
        if ($rc != PLUGIN_FINAL) {
            $c->error("Error in section ($section->[0])", 'crit');
            return PLUGIN_ERROR;
        }
    }

    return PLUGIN_SUCCESS;
}

sub post_tidy {
}

# Take a list of installed and to install and build a list
# of to remove and missing, taking account of deps and new_deps
sub calc_missing {
    my ($c, $instance_conf, undef, $section) = @_;
    my $s = $instance_conf->{store};

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $node;
    # Need to be installed
    foreach ($s->find_node('install')) {
        unless ($s->find_node('installed', 'name', $s->get_node_val('name', $_))) {
            $node = $s->create_node('missing');
            $s->copy_node($_, $node);
        }
    }
    return PLUGIN_FINAL;
}

sub calc_remove {
    my ($c, $instance_conf, undef, $section) = @_;
    my $s = $instance_conf->{store};
    my $name;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    foreach ($s->find_node('installed')) {
        $name = $s->get_node_val('name', $_);
        unless ($s->find_node('deps', 'name', $name) ||
                $s->find_node('install', 'name', $name) ||
                $s->find_node('new_deps', 'name', $name)) {
            $s->copy_node($_, $s->create_node('remove'));
        }
    }
    return PLUGIN_FINAL;
}

# For the list of packages that is to be kept on the system
# work out what packages they need so we don't remove them
# XXX it will not make sure all dpes are met. IF a dep is not
# installed (which would mean something is broken it will neither
# notice or report
sub resolve_deps {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    # TODO: make this cleaner
    my $s = $instance_conf->{store};

    my @installed = $s->find_node('installed');
    my $pkg;

    # build out a hash provides and packages names mapped to package
    # and a list of what packages depend on
    my %prov_lookup;
    my %dep_lookup;
    my %installed;
    foreach $pkg ($s->get_node_val([ 'name', 'provides', 'requires'], @installed)){
        $installed{$pkg->[0]} = undef;
        foreach (@{$pkg->[1]}) {
            unless (exists $prov_lookup{$_}) {
                $prov_lookup{$_} = [];
            }
            push @{$prov_lookup{$_}}, $pkg->[0];
        }
        $dep_lookup{$pkg->[0]} = $pkg->[2];
    }

    my %missing = map { $_ => undef } $s->get_node_val('name', $s->find_node('missing'));
    my @pkgs = $s->get_node_val('name', $s->find_node('install'));
    my %install = map { $_ => undef } @pkgs;
    my %processed;
    while(@pkgs) {
        my @new_pkgs;
        foreach (@pkgs) {
            # We only do installed deps
            next if (exists $missing{$_});
            foreach (@{$dep_lookup{$_}}) {
                # This deals with deps where there is an '|' (OR)
                # XXX: used in DEB pkgs. Not sure if this should be here
                #      maybe make it flexable...
                foreach (split(/\s*\|\s*/, $_)) {
                    # have processed this one before.
                    next if exists $processed{$_};
                    if (exists $installed{$_}) {
                        $s->copy_node($s->find_node('installed', 'name', $_),
                                      $s->create_node('deps'));
                        push @new_pkgs, $_;
                        $processed{$_} = undef;
                        next;
                    }
                    foreach $pkg (@{$prov_lookup{$_}}) {
                        # No point marking a dep for something in the install list
                        next if exists $install{$pkg};
                        $s->copy_node($s->find_node('installed', 'name', $pkg),
                                      $s->create_node('deps'));
                        # use to resolve it's deps next run;
                        push @new_pkgs, $pkg;
                        $processed{$pkg} = undef;
                    }
                }
            }
        }
        @pkgs = @new_pkgs;
    }
    
    return PLUGIN_FINAL;
}

# Basic report of what is about to happen
sub report {
    my ($c, $instance_conf, undef, $section) = @_;
    my $s = $instance_conf->{store};

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    $c->cprint("Going to....");
    my @names;
    foreach my $report (['    update:', 'updates'],
                        ['       add:', 'missing'],
                        ['  add deps:', 'new_deps'],
                        ['    remove:', 'remove'],) {
    
        
        @names = $s->get_node_val('name', $s->find_node($report->[1]));
        next unless (@names > 0);
        $c->cprint(join(' ', $report->[0], @names));
    }

    return PLUGIN_FINAL;
}
1;

# small package to be used in things like overlay templates
package Spine::Plugin::PackageManager::DataHelper;
use strict;
use Spine::Plugin::PackageManager;
sub new {
    my ($class, $c, $inst) = @_;
    return undef unless (defined $inst);
    my $self = bless { }, $class;
    $self->{store} = Spine::Plugin::PackageManager::get_store($inst);
    return undef unless defined ($self->{store});
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
    my ($class, $pkg) = @_;

    return
      bless {
             store  => {},
            }, $class;
}

# create a node in a store
sub create_node {
    my $self = shift;
    my ($store, @args) = @_;
    
    $self->{store}->{$store} = [] unless exists $self->{store}->{$store};
    my $node = {};
    push @{$self->{store}->{$store}}, $node;
    $node = [ $self->{store}->{$store}, $node ];
    $self->set_node_val($node, @args);
    return $node;
}

# add a node to a store, only to be used after a remove_node call
sub add_node {
    my $self = shift;
    my ($store, $node, @args) = @_;
    if (defined $node->[0]) {
        # we don't allow nodes to be in two places
        return undef;
    }
    $self->{store}->{$store} = [] unless exists $self->{store}->{$store};
    push @{$self->{store}->{$store}}, $node;
    $node = [ $self->{store}->{$store}, $node ];
    $self->set_node_val($node, @args);
    return $node;
}

# Fine either all nodes in a store,
# or all nodes in a <store> with a <key>
# or all nodes in a <store> with a <key> of <value> ... <key> <value>
# values of undef are take to mean as long as the key exists.
sub find_node {
    my $self = shift;
    my ($store, @where) = @_;

    return undef unless (exists $self->{store}->{$store});

    my (@result, $key, $value, $node);
    NODE: foreach $node (@{$self->{store}->{$store}}) {
        for (my $i = 0; $i < $#where ; $i = $i+2) {
            $key = $where[$i];
            $value = $where[$i+1];
            unless (exists $node->{$key} &&
                    (!defined $value || $node->{$key} eq $value)) {
                next NODE;
            }
        }
        push @result, [ $self->{store}->{$store}, $node ];
    } 

    return wantarray ? @result : (exists $result[0] ? $result[0] : undef);
}

# list the current store names
sub list_stores {
    my $self = shift;
    return keys %{$self->{store}}
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
        for (my $i = 0 ; $i < @{$node->[0]} ; $i++) {
            if ($node->[1] == $node->[0]->[$i]) {
                delete $node->[0]->[$i];
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
    my ($src, $dst) = @_;
    return %{$dst->[1]} = %{$src->[1]};
}

# set one or move value of a node
sub set_node_val {
    my $self = shift;
    my ($node, @data) = @_;

    # since find_node can return undef it's worth checking.
    return  0 unless defined $node;

    my ($key, $value);
    while ($key = shift @data) {
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
    my ($key, @nodes)  = @_;
    my @result;
    my $node;
    foreach $node (@nodes) {
        # since find_node can return undef it's worth checking.
        next unless defined $node;
        if (ref($key)) {
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
