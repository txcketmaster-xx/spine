# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# Copyright 2013 Metacloud, Inc
# All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

package Spine::Plugin::Pacemaker;
use base qw(Spine::Plugin);
use File::Temp qw(:mktemp);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $FORCE);

$FORCE = 0;
$VERSION = sprintf("%d", q$Revision: 163 $ =~ /(\d+)/);
$DESCRIPTION = "Plugin to configure pacemaker";

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
my $CRMADMIN = '/usr/sbin/crmadmin';
my $CRM_NODE = '/usr/sbin/crm_node';
my $CRM_ATTR = '/usr/sbin/crm_attribute';
my $CRM_SHADOW = '/usr/sbin/crm_shadow';
my $CRM_SIMULATE = '/usr/sbin/crm_simulate';
my $CAT = '/bin/cat';
my $PTEST = '/usr/sbin/ptest';
my $CRM_VERIFY = '/usr/sbin/crm_verify';
my $PACEMAKERD = '/usr/sbin/pacemakerd';
my @REQUIRED_ATTRIBUTES = ( 'cluster-infrastructure',
                            'dc-version' );
my @OPTIONAL_ATTRIBUTES = ( 'last-lrm-refresh' );                           

sub configure_pacemaker {
    my $c = shift;
    my $hostname = $c->getval('c_hostname');

    # Get our commands.
    get_cmdlines($c);

    # Lets see if pacemaker is even installed.
    if ( ! -x $PACEMAKERD ) {
        $c->print(1, "$PACEMAKERD not found, skipping");
        return PLUGIN_SUCCESS;
    }

    # Figure out if we have config files to load.
    my $conf_dir = '/etc/pacemaker/conf.d';
    if ($c->getval('pacemaker_config_dir')) {
        $conf_dir = $c->getval('pacemaker_config_dir');
    }
    my $dryrun = 0;
    $dryrun = $c->getval('c_dryrun');
    if ($dryrun) {
        $conf_dir = $c->getval('c_tmpdir') . $conf_dir;
    }
    my @config_files = ();
    foreach my $file (<$conf_dir/*.conf>) {
        if ( -f $file ) {
            push(@config_files, $file);
        }
    }
    if (scalar (@config_files) == 0) {
        $c->print(1, 'no config files found, skipping');
        return PLUGIN_SUCCESS;
    }

    # Get our commands. Again.
    get_cmdlines($c);

    # Get the master server in the cluster and the cluster status.
    my ($status, $master) = get_master($c);
    return PLUGIN_FATAL unless ($status == 0);
    my ($status, $cluster_status) = get_cluster_status($c);
    return PLUGIN_FATAL unless ($status == 0);

    # Figure out if we are the master node.
    $c->print(1, "master node is $master");
    if (($master ne $hostname) and (! $FORCE)) {
        $c->print(1, 'not master node, skipping');
        return PLUGIN_SUCCESS;
    }

    # Parse the cluster status.
    if (! ($cluster_status == 1) and (! $FORCE)) {
        $c->print(1, 'cluster status is not OK, skipping');
        return PLUGIN_SUCCESS;
    } else {
        $c->print(1, "cluster status is OK");
    }

    # Warn us if we are in override mode.
    if ($FORCE) {
        $c->error('forcing override', 'warn');
    }

    # We need to get a few config attributes from the existing config.
    my %saved_attributes;
    foreach my $attr (@REQUIRED_ATTRIBUTES) {
        my ($status, $value) = get_attr($c, $attr, 1);
        return PLUGIN_FATAL unless ($status == 0);
        $saved_attributes{$attr} = $value;
    }
    foreach my $attr (@OPTIONAL_ATTRIBUTES) {
        my ($status, $value) = get_attr($c, $attr, 0);
        if ($status == 0) {
            $saved_attributes{$attr} = $value;
        }
    }
    if ($c->getval('pacemaker_required_attributes')) {
        foreach my $attr ($c->getvals('pacemaker_required_attributes')) {
            my ($status, $value) = get_attr($c, $attr, 1);
            return PLUGIN_FATAL unless ($status == 0);
            $saved_attributes{$attr} = $value;
        }
    }
    if ($c->getval('pacemaker_optional_attributes')) {
        foreach my $attr ($c->getvals('pacemaker_optional_attributes')) {
            my ($status, $value) = get_attr($c, $attr, 0);
            if ($status == 0) {
                $saved_attributes{$attr} = $value;
            }    
        }
    }

    # Test to see if already have a shadow config
    my $shadow_name = 'spine';
    if ($c->getval('pacemaker_shadow_name')) {
        $shadow_name = $c->getval('pacemaker_shadow_name');
    }
    my @shadow_files = ();
    push(@shadow_files, "/var/lib/heartbeat/crm/shadow.$shadow_name");
    push(@shadow_files, "/var/lib/pacemaker/cib/shadow.$shadow_name");
    foreach my $shadow_file (@shadow_files) {
        if ( -f $shadow_file ) {
            $c->error("existing shadow config found at $shadow_file", 'err');
            return PLUGIN_FATAL;
        } 
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

    # For performance reasons we create a single config file that we load.
    my $tmpfile = mktemp('/tmp/pacemaker.XXXXXX');
    open (OUTFILE , ">$tmpfile");
    foreach my $file (@config_files) {
        open (INFILE , "<$file");
        foreach my $line (<INFILE>) {
            print OUTFILE $line;
        }
        close (INFILE);
    }
    close (OUTFILE);

    $c->print(2, 'Generating new cluster configuration');
    # Now we need to load each file into the configuration.
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 0, $CRM,
                                     "configure load update $tmpfile");
    _exec_cmd($c, 1, 0, '/bin/rm', $tmpfile);
    # Some errors are only reported in stdout/stderr no return status.
    if (($status != 0) 
            or (scalar(@stdout) != 0) or (scalar(@stderr) != 0)) {

        if ($status != 0) {
            $c->error("\"$CRM configure load update $tmpfile\""
                        . " returned $status", 'err');
        } else {
            $c->error("\"$CRM configure load update $tmpfile\""
                        . " returned an error", 'err');
        }
        foreach my $line (@stdout, @stderr) {
            next if ($line =~ m/^\s*$/);
            $c->error($line, 'err');
        }

        delete_shadow($c, $shadow_name);
        return PLUGIN_FATAL;
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
    } else {
        $c->print(2, 'Configuration diff:');
        foreach my $line (@diff) {
            $c->cprint("    $line", 2, 0) if ($line =~ /^[+-]/);
        }
    }

    # Now that the config is compiled we need to determine what version we are
    # running and check the config.
    my $version = '0';
    ($status, $version) = get_version($c);
    if ($status != 0) {
        # get_version already parsed the output and logged
        delete_shadow($c, $shadow_name);
        return PLUGIN_FATAL;
    }

    # Lets do a final verification of the new config.
    # Return status of 0 is all good, 1 is warnings (like removing a resource)
    # and 2 means errors.
    $c->print(2, 'Verifying new cluster configuration');
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 0, $CRM_VERIFY,
                                     '-L -V');
    if ($status != 0) {
        if ($status == 2) {
            # Hard error, parse the output and exit with an error.
            $c->error('crm_verify returned an error', 'err');
            parse_output($c, 'crm_verify', 'err', $version, (@stdout, @stderr));
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        } elsif ($status == 1) {
            # There was a warning.
            $c->error('crm_verify returned a warning', 'warn');
            parse_output($c, 'crm_verify', 'warn', $version, (@stdout, @stderr));
        } else {
            # Unknown status.
            $c->error("crm_verify returned unknown status $status", 'err');
            parse_output($c, 'crm_verify', 'err', $version, (@stdout, @stderr));
            delete_shadow($c, $shadow_name);
            return PLUGIN_FATAL;
        }
    }

    # OK print or state transitions
    use feature "switch";
    $c->print(2, 'Cluster Action Simulation:');
    given ($version) {
        when (/^1\.1\.6$/) {
            # crm_simulate doesn't work in 1.1.6 so we use ptest instead.
            my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $PTEST,
                                             '--live-check -VVV -S');
            if ($status != 0) {
                $c->error("ptest returned $status", "err");
                delete_shadow($c, $shadow_name);
                return PLUGIN_FATAL;
            }
            parse_output($c, 'ptest', 'info', $version, (@stdout, @stderr));
        }
        default {
            my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 1, $CRM_SIMULATE,
                                             '-S -L');
            if ($status != 0) {
                $c->error("crm_simulate returned $status", "err");
                delete_shadow($c, $shadow_name);
                return PLUGIN_FATAL;
            }
            # We only want to print certain sections
            my $capture = 0;
            foreach my $line (@stdout) {
                # If the line is the start of a section we care about go into
                # capture mode.
                if (($line =~ m/^Transition\sSummary:$/i) || 
                   ($line =~ m/^Executing\scluster\stransition:$/i)) {
                   $capture = 1;
                }
                if ($capture) {
                    # If we are are in capture mode, log the line.
                    chomp $line;
                    $c->print(2, " $line");
                    # If the line is a blank line its the end of a section so
                    # exit capture mode.
                    if ($line =~ m/^$/i) {
                        $capture = 0;
                    }
                }
            }
        }
    }

    # Now we get to actually load the config.
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
    if ($c->getval('pacemaker_pacemakerd')) {
        $PACEMAKERD = $c->getval('pacemaker_pacemakerd');
    }
}

sub get_version {
    my $c = shift;
    my $status = 0;
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, 0, $CRM_VERIFY,
                                               '--version');
    my $version = 0;
    if ($status != 0) {
        $c->error('crm_verify --version returned an error', 'err');
        parse_output($c, 'crm_verify', 'err', $version, (@stdout, @stderr));
        return ($status, $version);
    }
    foreach my $line (@stdout) {
        next unless ($line =~ m/^Pacemaker\s(.+)/i);
        $version = $1;
        last;
    }
    return ($status, $version);
}

sub get_master {
    my $c = shift;
    my $status = 0;
    # Call crm status
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1 , 1, $CRMADMIN, '-D -q');

    # Parse the output to get the current DC.
    my $master = '';
    foreach my $line (@stdout) {
        next unless ($line =~ m/^Designated\sController\sis:\s(.+)/i);
        $master = $1;
        last;
    }
    return ($status, $master);
}

sub get_cluster_status {
    my $c = shift;
    my $status = 0;
    # Call crm status
    my ($status, @stdout, @stderr) = _exec_cmd($c, 1 , 1, $CRM_NODE, '-q');

    # Parse the output to get the current DC.
    my $cluster_status = '0';
    if ($status == 0) {
        $cluster_status = $stdout[0];
    }
    return ($status, $cluster_status);
}

sub get_attr {
    my $c = shift;
    my $attr = shift;
    my $report_error = shift;

    my ($status, @stdout, @stderr) = _exec_cmd($c, 1, $report_error, $CRM_ATTR,
                                     "--attr-name $attr");
    my $value = '';
    if ($status == 0) {
        my $escaped = quotemeta($attr);
        foreach my $line (@stdout) {
            next unless ($line =~ m/^scope=.+\s+name=($escaped)\svalue=(.*)$/);
            $value = $2;
            last;
        }
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
    my $version = shift;
    my @data = @_;

    foreach my $line (@data) {
        use feature "switch";
        given ($version) {
            when (/^1\.1\.6$/) {
                if ($line =~ m|^\w+\[\d+\]:\s\d{4}/\d{2}/\d{2}_\d{2}:\d{2}:\d{2}\s\w+:\s(.*)$|) {
                    $c->error("$tag: $1", $status);
                } else {
                    # No clue what this line is, print it.
                    $c->error("$tag: $line", $status);
                }
            }
            when (/^1\.1\.9$/) {
                # There is a bug in 1.1.9 that prints these lines incorrectly
                if ($line =~ m|crit: get_timet_now|) {
                    next;
                }
                $c->error("$tag: $line", $status);
            }
            default {
                # No clue what it is so just print it.
                $c->error("$tag: $line", $status);
            }
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
