# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

use strict;

package Spine::Plugin::Pacemaker;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $FORCE);

$FORCE = 0;
$VERSION = sprintf("%d", q$Revision: 163 $ =~ /(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'cfb@metacloud.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'configure_pacemaker',
                                    code => \&configure_pacemaker } ]
                     },
            cmdline => { _prefix => 'pacemaker',
                         options => {
                                     'force' => \$FORCE,
                                    }
                       }
          };

use Spine::Util qw(create_exec);
use Text::Diff;

# Defaults for the various cmd line programs we need.
my $CRM = '/usr/sbin/crm';
my $CRM_ATTR = '/usr/sbin/crm_attribute';
my $CRM_SHADOW = '/usr/sbin/crm_shadow';
my $CAT = '/bin/cat';
my $PTEST = '/usr/sbin/ptest';
my $CRM_VERIFY = '/usr/sbin/crm_verify';
my @REQUIRED_ATTRIBUTES = ( 'cluster-infrastructure',
                            'dc-version',
                            'last-lrm-refresh' );

sub configure_pacemaker {
    my $c = shift;
    my $hostname = $c->getval('c_hostname');

    # Figure out if we have config files to load.
    my $conf_dir = '/etc/pacemaker/conf.d';
    my @config_files = ();
    if ($c->getval('pacemaker_config_dir')) {
        $conf_dir = $c->getval('pacemaker_config_dir');
    }    
    foreach my $file (<$conf_dir/*>) {
        if ( -f $file ) {
            push(@config_files, $file);
        }
    }
    if (scalar (@config_files) == 0) {
        $c->error('no config files found, skipping', 'warn');
        return PLUGIN_SUCCESS;
    }

    # Get our commands.
    get_cmdlines($c);

    # Get the master server in the cluster and the cluster status.
    my ($status, $master, $cluster_status) = get_status($c);
    return PLUGIN_FATAL unless ($status == 0);

    # Figure out if we are the master node.
    $c->print(1, "master node is $master");
    if (($master ne $hostname) and (! $FORCE)) {
        $c->print(1, 'not master node, skipping');
        return PLUGIN_SUCCESS;
    }

    # Parse the cluster status.
    $c->print(1, "cluster status is $cluster_status");
    if (! ($cluster_status =~ /^partition with quorum$/) and (! $FORCE)) {
        $c->print(1, 'cluster status is not OK, skipping');
        return PLUGIN_SUCCESS;
    }

    # Warn us if we are in override mode.
    if ($FORCE) {
        $c->error('forcing override', 'warn');
    }

    # We need to get a few config attributes from the existing config.
    my %saved_attributes;
    foreach my $attr (@REQUIRED_ATTRIBUTES) {
        my ($status, $value) = get_attr($c, $attr);
        return PLUGIN_FATAL unless ($status == 0);
        $saved_attributes{$attr} = $value;
    }
    if ($c->getval('pacemaker_saved_attributes')) {
        foreach my $attr ($c->getvals('pacemaker_saved_attributes')) {
            my ($status, $value) = get_attr($c, $attr);
            return PLUGIN_FATAL unless ($status == 0);
            $saved_attributes{$attr} = $value;
        }
    }    

    # Test to see if already have a shadow config
    my $shadow_name = 'spine';
    if ($c->getval('pacemaker_shadow_name')) {
        $shadow_name = $c->getval('pacemaker_shadow_name');
    }
    my $shadow_file = "/var/lib/heartbeat/crm/shadow.$shadow_name";
    if ( -f $shadow_file ) {
        $c->error("existing shadow config found at $shadow_file", 'error');
        return PLUGIN_FATAL;
    }

    # Capture the old config so we can diff it.
    my ($status, @OLD_CONFIG) = get_config($c);
    return PLUGIN_FATAL unless ($status == 0);

    # Lets create a shadow config.
    my ($status, $stdout, $stderr) = _exec_cmd($c, 1, 1, $CRM_SHADOW,
                                     "-b --create $shadow_name");
    return PLUGIN_FATAL unless ($status == 0);
    
    # Now that we have a shadow config, we need to use it.
    $ENV{'CIB_shadow'} = $shadow_name;

    # crm_shadow makes a copy of the current config. 
    # nuke it as we are going to build ours from scratch.
    my ($status, $stdout, $stderr) = _exec_cmd($c, 1, 1, $CRM,
                                     'configure erase');

    if ($status != 0) {
        delete_shadow($c, $shadow_name); 
        return PLUGIN_FATAL;
    }

    # Loop through all our saved attributes and set them
    foreach my $attr (sort (keys(%saved_attributes))) {
        my $status = set_attr($c, $attr, $saved_attributes{$attr});
        if ($status != 0) {
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        }
    }

    # Now we need to load each file into the configuration.
    foreach my $file (@config_files) {
        my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM,
                                         "configure load update $file");
        if ($status != 0) {
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        }
    }

    # Now capture the new config so we can diff it with the old one.
    my ($status, @NEW_CONFIG) = get_config($c);
    if ($status != 0) {
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
    }        

    # Diff the old and new configs to see if anything changed.
    my $diff = diff(\@OLD_CONFIG, \@NEW_CONFIG);
    if (length($diff) == 0) {
        # No change to the config, clenaup and return.
        delete_shadow($c, $shadow_name);
        return PLUGIN_SUCCESS;
    }

    my @diff = split(/\n/, $diff);
    my $max_diff_lines = $c->getval('max_diff_lines_to_print');

    my $size = scalar(@diff);

    if (defined($max_diff_lines) 
        and $max_diff_lines > 0
        and $size >= $max_diff_lines) {

        $c->print(2, "Changes to config are too large to print("
                     . "$size >= $max_diff_lines lines)");
    }
    else {
        foreach my $line (@diff) {
            $c->cprint("    $line", 2, 0) if ($line =~ /^[+-]/);
        }
    }

    # Lets do a final verification of the new config.
    # Return status of 0 is all good, 1 is warnings (like removing a resource)
    # and 2 means errors.
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 0, $CRM_VERIFY,
                                     '-L -V');
    if ($status != 0) {
        if ($status == 2) {
            # Hard error, parse the output and exit with an error.
            $c->error('crm_verify returned an error', 'err');
            parse_output($c, 'crm_verify', 'err', (@stdout, @stderr));
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        } elsif ($status == 1) {
            # There was a warning.
            $c->error('crm_verify returned a warning', 'warn');
            parse_output($c, 'crm_verify', 'warn', (@stdout, @stderr));
        } else {
            # Unknown status.
            $c->error("crm_verify returned unknown status $status", 'err');
            parse_output($c, 'crm_verify', 'err', (@stdout, @stderr));
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        }
    }

    # OK print or state transitions
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $PTEST,
                                     '--live-check -VVV -S');
    if ($status != 0) {
        delete_shadow($c, $shadow_name);
        return PLUGIN_FATAL;
    }
    parse_output($c, 'ptest', 'info', (@stdout, @stderr));

    # Now we get to actually load the config.
    my $dryrun = 0;
    $dryrun = $c->getval('c_dryrun');
    if (! $dryrun) {
        $c->print(1, 'commiting cluster configuration');
        my ($status, @stdout, @stderr) = _exec_cmd($c, 0, 1, $CRM_SHADOW,
                                         "--commit $shadow_name --force");

        # Doesn't matter what happened we remove the shadow config.
        if ($status != 0) {
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        }
    }

    # We got this far so just cleanup.
    delete_shadow($c, $shadow_name);
    return PLUGIN_SUCCESS;
}

# Check the config tree to see if we there are any cmdline overrides.
sub get_cmdlines {
    my $c = shift;

    if ($c->getval('pacemaker_crm_bin')) {
        $CRM = $c->getval('pacemaker_crm_bin');
    }
    if ($c->getval('pacemaker_crm_attr_bin')) {
        $CRM_ATTR = $c->getval('pacemaker_crm_attr_bin');
    }
    if ($c->getval('pacemaker_crm_shadow_bin')) {
        $CRM_SHADOW = $c->getval('pacemaker_crm_shadow_bin');
    }
    if ($c->getval('pacemaker_cat_bin')) {
        $CAT = $c->getval('pacemaker_cat_bin');
    }
    if ($c->getval('pacemaker_ptest_bin')) {
        $PTEST = $c->getval('pacemaker_ptest_bin');
    }
    if ($c->getval('pacemaker_crm_verify_bin')) {
        $CRM_VERIFY = $c->getval('pacemaker_crm_verify_bin');
    }
}

sub get_status {
    my $c = shift;

    # Call crm status
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1 , 1, $CRM, 'status');

    # Parse the output of crm status looking for our DC and cluster status.
    my $master = '';
    my $cluster_status = '';
    foreach my $line (@stdout) {
        next unless ($line =~ m/^Current\sDC:\s(.+)\s-\s(.+)/i);
        $master = $1;
        $cluster_status = $2;
        last;
    }

    return ($status, $master, $cluster_status);
}

sub get_attr {
    my $c = shift;
    my $attr = shift;

    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM_ATTR,
                                     "--attr-name $attr");
    my $value = '';
    my $escaped = quotemeta($attr);
    foreach my $line (@stdout) {
        next unless ($line =~ m/^scope=.+\s+name=($escaped)\svalue=(.*)$/);
        $value = $2;
        last;
    }

    return ($status, $value);
}

sub set_attr {
    my $c = shift;
    my $attr = shift;
    my $value = shift;

    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM_ATTR,
                                     "--attr-name $attr --attr-value $value");
    return $status;
}

sub get_config {
    my $c = shift;

    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM,
                                     '-D plain configure show');
    return ($status, @stdout);
}

sub delete_shadow {
    my $c = shift;
    my $shadow_name = shift;

    if ($c->getval('pacemaker_keep_shadow')) {
        $c->print(1, 'keeping shadow config');
        $c->print(1, "remove with 'crm_shadow -D $shadow_name'" 
                   . 'before next spine run');
        return 0;
    }    

    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM_SHADOW,
                                     "-D $shadow_name --force");
    return $status;
}

sub parse_output {
    my $c = shift;
    my $tag = shift;
    my $status = shift;
    my @data = @_;

    foreach my $line (@data) {
        if ($line =~ m|^\w+\[\d+\]:\s\d{4}/\d{2}/\d{2}_\d{2}:\d{2}:\d{2}\s\w+:\s(.*)$|) {
            $c->error("$tag: $1", $status);
        } else {
            # No clue what this line is, print it.
            $c->error("$tag: $line", $status);
        }
    }
}

sub _exec_cmd {
    my $c = shift;
    my $inert = shift;
    my $report_errors = shift;
    my $cmd = shift;
    my $args = shift;

    my $exec = create_exec(inert => $inert,
                           c     => $c,
                           exec  => $cmd,
                           args  => $args);

    unless ($exec->start()) {
        $c->error("\"$cmd $args\" failed to run", 'err');
        return 1, undef, undef;
    }

    $exec->closeinput();

    my @stdout = $exec->readlines();
    my @stderr = $exec->readerrorlines();

    $exec->wait();

    my $status = $exec->exitstatus() >> 8;

    # See if we got an error and output the results
    if (($status != 0) and ($report_errors)) {
        $c->error("\"$cmd $args\" returned $status", 'err');
        foreach my $line (@stdout, @stderr) {
            next if ($line =~ m/^\s*$/);
            $c->error($line, 'err');
        }
        return ($status, undef, undef);
    }

    return ($status, @stdout, @stderr);
}

1;
