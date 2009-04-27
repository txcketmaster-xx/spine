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

package Spine::Registry;
use base qw(Spine::Singleton Exporter);
use Carp qw(cluck);
use Spine::Constants qw(:basic :plugin);
use Spine::Chain;

our ($VERSION, $DEBUG, @EXPORT, @EXPORT_OK);

$DEBUG = $ENV{SPINE_REGISTRY_DEBUG} || 0;
$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

@EXPORT_OK = qw(register_plugin create_hook_point add_option get_options
                add_hook get_hook_point install_method get_plugin_version);

# XXX The following control host the registery will deal with loading hooks
#     it will probably be removed once the design is finalized.
# Will allow a request to hook into a hook point to happen
# before the hook point has been registered. 
our $DELAYEDREG = 1;
# If a plugin gets loaded while this is '1' it will load all it's hooks
# FIXME: this implementation isn't very nice. IF you try to make it better
#        just search for AUTOHOOK and you will fine all the offending code
our $AUTOHOOK = 0;

sub _new_instance
{
    my $klass = shift;

    # XXX: Requested points is used to track points that arrive
    #      before the hook is registered
    return bless { CONFIG => shift,
                   PLUGINS => {},
                   POINTS => {},
                   REQUESTED_POINTS => {},
                   OPTIONS => {}
                 }, $klass;
}

#
# Method to retrieve a given plugin's version
#
sub get_plugin_version
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my $plugin_name = shift;
    $plugin_name = 'Spine::Plugin::' . $plugin_name;

    if (exists($registry->{PLUGINS}->{$plugin_name}->{version})) {
        return $registry->{PLUGINS}->{$plugin_name}->{version};
    }
    else {
        return undef;
    }
}

#
# Adds a new entry in our "points" location that a plugin can hook at.
#
sub create_hook_point
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my $CONFIG = $registry->{CONFIG};

    foreach my $new_point (@_) {
        debug(5, "\tCreating hook point \"$new_point\"");

        if (exists($registry->{POINTS}->{$new_point})) {
            error("Attempt to register existing hook point: \"$new_point\"");
            next;
        }

        my @caller = caller();
        # FIXME  Do we want a Spine::HookPoint class for decent abstractness?
        my $point = new Spine::Registry::HookPoint(name => $new_point,
                                                   'caller' => \@caller);

        $registry->{POINTS}->{$new_point} = $point;

        # If DELAYEDREG is set then we allow loading of items to be hooked before
        # the hook is been setup. Best check if anything has used that
        if ($DELAYEDREG && exists($registry->{REQUESTED_POINTS}->{$new_point})) {
            foreach (@{$registry->{REQUESTED_POINTS}->{$new_point}}) {
                my $auto_tmp = $AUTOHOOK;
                $AUTOHOOK = $_->[2];
                $point->install_hook($_->[0],
                                     $_->[1]);
                $AUTOHOOK = $auto_tmp;
            }
            delete $registry->{REQUESTED_POINTS}->{$new_point};
        }
    }

    return SPINE_SUCCESS;
}


#
# Try to load the plain filename as is first but fallback to something in the
# Spine::Plugin namespace
#
# There's no problem problem with plugins being loaded repeatedly, since they
# should all be singletons.
#
sub load_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my $rc = SPINE_SUCCESS;
    my $module;

    foreach my $plugin (@_) {
        eval "require $plugin";

        if ($@) {
            if ($plugin =~ m/^Spine::Plugin::/) {
                error("Failed to find or load $plugin: $@");
                $rc = SPINE_FAILURE;
                next;
            }

            # And our fallback
            eval "require Spine::Plugin::$plugin";

            if ($@) {
                error("Failed to find or load $plugin fallback as ",
                      "\"Spine::Plugin::$plugin\": $@");
                $rc = SPINE_FAILURE;
                next;
            }
        }

        $plugin = 'Spine::Plugin::' . $plugin;

        eval {
            $module = $plugin->new();
        };

        if ($@ or not defined($module)) {
            error("Failed to instantiate plugin \"$plugin\": $@");
            $rc = SPINE_FAILURE;
        }
    }

    return SPINE_SUCCESS;
}


#
# Registers a plugin with the registry without actually doing much useful work.
# Currently only populates our command line options.
#
sub register_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my ($plugin, $module) = @_;

    unless (UNIVERSAL::isa($plugin, 'Spine::Plugin')) {
        error('Invalid object given as first parameter to register_plugin: ',
              ref($plugin));
        return SPINE_FAILURE;
    }

    my $module_name = ref($plugin);

    debug(2, "\tRegistering plugin \"$module_name\"");

    # If this plugin has already been registered, notify but continue on
    if (exists($registry->{PLUGINS}->{ref($plugin)})) {
        debug(2, "Duplicate registration of plugin: \"$module_name\"");
        return SPINE_SUCCESS;
    }

    $registry->{PLUGINS}->{$module_name} = $module;

    # We register command line stuff first because it's possible that the
    # hook points supported by this particular plugin don't exist.

    # Register this plugin's command line options
    if (exists($module->{cmdline})) {
        unless ($registry->add_option($module_name, $module->{cmdline})) {
            error("Failed to register command line for \"$module_name\"");
            return SPINE_FAILURE;
        }
    }

    # Load all hooks if we have been told to
    if ($AUTOHOOK) {
        # Register this plugin's hooks so that other hooks can manipulate them.
        foreach my $hook_point (keys(%{$module->{hooks}})) {
            debug(5, "hook point name: ($hook_point)");
            
            # Track missing hooks
            unless (exists($registry->{POINTS}->{$hook_point})) {
                # If we are not allowed to use delayed reg then tell the user
                # that this will never manager to hook into the requested point
                unless ($DELAYEDREG) {
                    error("Attempt to hook into missing hook point.".
                          "Module \"$module_name\", Hook $hook_point");
                    next;
                }

                # Store the information about the hook request so that it can be
                # used later.
                unless (exists($registry->{REQUESTED_POINTS}->{$hook_point})) {
                    $registry->{REQUESTED_POINTS}->{$hook_point} = [];
                }
                # AUTOHOOK gets stored so we know to load all it's hooks
                push @{$registry->{REQUESTED_POINTS}->{$hook_point}}, [ $module_name, $module, $AUTOHOOK ];
                debug(5, "Hook point is not there, maybe later: $hook_point");
                debug(5, 'Skipping for now.');
                next;
            }

            # Install the new hooks
            $registry->{POINTS}->{$hook_point}->install_hook($module_name,
                                                             $module);
        }
    }

    return SPINE_SUCCESS;
}


sub find_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my @plugins;
    my $PLUGINS = $registry->{PLUGINS};

    #
    # Looks for the plugin name in the Spine::Plugin::* namespace first and
    # if it fails to find it, attempts to find the plugin by itself.
    #
    foreach my $candidate (@_) {
        foreach my $module ( ("Spine::Plugin::$candidate", $candidate) ) {
            if (exists($PLUGINS->{$module})) {
                push @plugins, $module;
                last;
            }
        }
    }

    # FIXME  ??  unshift or shift?
    unless (wantarray) {
        return unshift @plugins;
    }

    return @plugins;
}

sub add_option
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my (%cmdline, $prefix);
    my $plugin = shift;

    # If we were passed a hashref then try to be smart.
    if (ref($_[0]) eq 'HASH') {
        %cmdline = %{ shift() };
    }
    else {
        %cmdline = @_;
    }

    # Populate our prefix if it exists
    if (defined($cmdline{'_prefix'})) {
        $prefix = delete $cmdline{'_prefix'};
    }

    if (exists($registry->{OPTIONS}->{$plugin})) {
        error("Duplicate command line options entry for \"$plugin\"");
        return SPINE_FAILURE;
    }

    my $final = {};

    while (my ($opt, $target) = each(%{$cmdline{options}})) {
        $opt = defined($prefix) ? $prefix . '-' . $opt : $opt;

        if (exists($registry->{OPTIONS}->{$opt})) {
            error("Duplicate command option specific by $plugin: \"$opt\"");
            return SPINE_FAILURE;
        }

        $registry->{OPTIONS}->{$opt} = $target;
    }

    return SPINE_SUCCESS;
}


sub get_options
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    return $registry->{OPTIONS};
}


sub get_hook_point
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my @points;

    foreach my $hook_point (@_) {
        unless (exists($registry->{POINTS}->{$hook_point})) {
            # XXX: Now we store requests for hook points they can
            #      be created when used is needed.
            unless ($registry->create_hook_point($hook_point)) {
                cluck("Invalid hook point \"$hook_point\"");
                next;
            }
        }

        push @points, $registry->{POINTS}->{$hook_point};
    }

    if (scalar(@_) == 1 and scalar(@points) == 1) {
        return shift @points;
    }

    return wantarray ? @points : \@points;
}



sub install_method
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
	shift;
    }

    my ($method_name, $coderef) = @_;

    my $dest = 'Spine::Data::' . $method_name;

    no strict 'refs';
    if (defined(*{$dest})) {
        error("Duplcate method in Spine::Data: \"$method_name\"");
        return SPINE_FAILURE;
    }

    *{$dest} = $coderef;
    use strict 'refs';

    return SPINE_SUCCESS;
}

sub error
{
    print STDERR 'REGISTRY ERROR: ', @_, "\n";
}


sub debug
{
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "REGISTRY DEBUG($lvl): ", @_, "\n";
    }
}




##############################################################################
#
# Finally needed to create a Spine::Registry::HookPoint class
#
##############################################################################

package Spine::Registry::HookPoint;
use Spine::Constants qw(:plugin :basic);

our $DEBUG = $ENV{SPINE_REGISTRY_DEBUG} || 0;

sub new
{
    my $klass = shift;
    my %args = @_;

    my $self = bless { name => $args{name},
                       owner => $args{'caller'} ? $args{'caller'} : undef,
                       parameters => $args{parameters} ? $args{parameters} : [],
                       states => {},
                       hooks => new Spine::Chain,
                       status => SPINE_NOTRUN,
                       registered => SPINE_NOTRUN }, $klass;

    return $self;
}


sub add_parameter
{
    my $self = shift;

    return push @{ $self->{parameters} }, @_;
}


sub register_hooks
{
    my $self = shift;
    my $registry = Spine::Registry->instance();

    unless ($self->{registered} == SPINE_NOTRUN) {
        return $self->{registered};
    }

    $self->debug(4, "\tRegistering hooks for hook point \"$self->{name}\"");


    # If we've already loaded our plugin lists, make sure we add populate
    # this hook point's children
    my $c = $registry->{CONFIG};
    my $phase_conf = $c->{$c->{spine}->{Profile}}->{$self->{name}};
    my @modules = $registry->find_plugin(split(/(?:\s*,?\s+)/, $phase_conf));

    foreach my $module (@modules) {
        unless ($self->install_hook($module, $registry->{PLUGINS}->{$module})) {
            $self->{registered} = SPINE_FAILURE;
            goto register_hooks_out;
        }
    }

    $self->{registered} = SPINE_SUCCESS;

  register_hooks_out:
    return $self->{registered};
}


sub install_hook
{
    my $self = shift;
    my $module_name = shift;
    my $module = shift;

    foreach my $h (@{$module->{hooks}->{$self->{name}}}) {
        $self->debug(5, "\t\tRegistering hook at \"$self->{name}\": ",
                     $h->{name});

        unless ($self->add_hook($module_name, $h)) {
            $self->error("Failed to add hook \"${module}::$h->{name}\" ",
                         "to \"$self->{name}\"");
            return PLUGIN_ERROR;
        }
    }

    return SPINE_SUCCESS;
}

sub head
{
    return $_[0]->{hooks}->head;
}

sub next
{
    if (UNIVERSAL::isa($_[0], 'Spine::Registry::HookPoint')) {
        shift;
    }
    return wantarray ? ($_[0]->{next}, $_[0]->{data}) : $_[0]->{next};
}

sub add_hook
{
    my $self = shift;

    my ($module_name, $h) = @_;

    # If $module is a reference to a Spine::Plugin object, convert it to a
    # string we can use for better error reporting.
    unless (ref($module_name) eq '') {
        $module_name = ref($module_name);
    }

    my $hook = { module => $module_name,
                 name => $h->{name},
                 code => $h->{code},
                 rc => PLUGIN_ERROR,
                 msg => undef };

    my %args = (name => $h->{name},
                data => $hook,
                provides => exists $h->{provides} ? $h->{provides} : undef,
                requires => exists $h->{requires} ? $h->{requires} : undef,
                position => exists $h->{position} ? $h->{position} : undef,
                successors => exists $h->{successors} ? $h->{successors} : undef,
                predecessors => exists $h->{predecessors} ? $h->{predecessors} : undef);

    $self->{hooks}->add(%args);

    return SPINE_SUCCESS;
}

sub run_hooks_until
{
    my $self = shift;
    my $until = shift;

    my $errors = 0;
    my $fatal = 0;
    my $rc;

    $self->debug(2, "Running hooks for \"$self->{name}\"");

    unless ($self->register_hooks() == SPINE_SUCCESS) {
        return PLUGIN_FATAL;
    }

    my ($hooks, $hook) = ($self->head, undef);
    while ($hooks && (($hooks, $hook) = $self->next($hooks))) {
        $rc = $self->run_hook($hook, @_);

        if ($rc == PLUGIN_ERROR) {
            $self->debug(2, "ERROR while running hook for \"$self->{name}\"");
            $errors++;
        }
        elsif ($rc == PLUGIN_EXIT) {
            $self->debug(2, "EXIT while running hook for \"$self->{name}\"");
            $fatal++;
        }

        if ($until & $rc) {
            $self->debug(3, "UNTIL while running hook for \"$self->{name}\"");
            last;
        }

    }

    if ($errors + $fatal) {
        $self->{status} = SPINE_FAILURE;
    }

    return wantarray ? ($rc, $errors, $fatal) : $rc;
}

# Done to keep backward compatibility, and it's simple
sub run_hooks {
    my $self = shift;
    my (undef, $errors, $fatal) = $self->run_hooks_until(undef, @_);
    return $errors + $fatal;
}


sub run_hook
{
    my $self = shift;
    my $hook = shift;
    my @parameters = @_;
    my $c = $parameters[0];

    #unless ($self->register_hooks() == SPINE_SUCCESS) {
    #    return PLUGIN_FATAL;
    #}

    $self->debug(3, "Running hook: $hook->{name}");
    $self->debug(6, 'Parameters: ', @parameters);

    unless (ref($hook) eq 'HASH'
            and ref($hook->{code}) eq 'CODE') {
        $self->error('Invalid hook passed to run_hook! ');
        $hook->{rc} = PLUGIN_FATAL;
        goto hook_error;
    }

    #
    # XXX Should this be required?  Probably.
    #
    unless ($c->isa('Spine::Data')) {
        $hook->{msg} = 'Invalid parameter passed to run_hook: "' . ref($_[0])
                       . '"';
        $hook->{rc} = PLUGIN_FATAL;
        $self->error($hook->{msg});
        goto hook_error;
    }

    my $old_label = $c->{c_label};
    # Take a label if one is given as the label else use the name
    $c->set_label($hook->{label} || $hook->{name});

    eval {
        # FIXME  This is going to be fugly to implement.
        #local $SIG{__DIE__} = \&_plugin_die;

        $hook->{rc} = &{$hook->{code}}(@parameters);
    };

    $c->set_label($old_label);

    # FIXME  Proper exception handling.
    if ($@) {
        $hook->{rc} = PLUGIN_FATAL;
        $hook->{msg} = $@;
        $self->error("Hook \"$hook->{module}::$hook->{name}\" failed: ", $@);
        goto hook_error;
    }

    unless (exists($self->{states}->{$hook->{rc}})) {
        $self->{states}->{$hook->{rc}} = [];
    }

    push @{$self->{states}->{$hook->{rc}}}, $hook;

    if ($hook->{rc} == PLUGIN_EXIT) {
        $self->debug(3, 'Hook "', $hook->{module}, '::', $hook->{name},
                     '" completed successfully but returned PLUGIN_EXIT');
    }

  hook_error:
    return $hook->{rc};
}


sub get_state
{
    my $self = shift;
    my $wanted = shift;

    my $states = $self->{states}->{$wanted};

    unless (defined($states)) {
        return wantarray ? () : [];
    }

    return wantarray ? @{$states} : $states;
}


sub error
{
    my $self = shift;

    print STDERR "REGISTRY ERROR($self->{name}): ", @_, "\n";
}


sub debug
{
    my $self = shift;
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "REGISTRY DEBUG($self->{name}:$lvl): ", @_, "\n";
    }
}


1;
