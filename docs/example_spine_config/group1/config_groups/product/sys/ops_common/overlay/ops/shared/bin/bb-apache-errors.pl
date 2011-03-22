#!/usr/bin/perl -w

$| = 1;

use Getopt::Long;
use Data::Dumper;

use Fcntl qw(:flock);

use strict;

$ENV{PATH} = "";

$::seekStateFile = "/tmp/.bb-apache-errors.pl.seekState";
$::thresholdsStateFile = "/ops/shared/htdocs/logs/.bb-apache-errors.pl.thresholdsState";
$::thresholdretentionTime = 604800;
$::commandLineReport = 0;
$::killSize = 125000;
$::killTime = 270;
$::hostname = `/bin/hostname`;
chomp($::hostname);
$::lockString = "$::hostname." . time . "." . $$;

GetOptions(
        \%::commandLineOptions,
        'seekStateFile=s',
        'seekStateFileInitialize',
	'thresholdsFile=s',
	'thresholdsStateFile=s',
	'summaryOnly',
	'help',
);

if (exists $::commandLineOptions{help}) {
        print STDERR "

Mr. Netops nifty error parser

options:
        -seekStateFile <seekStateFile>
                file to store state information in.
        -seekStateFileInitialize
                set seek state for the files and exit.
        -thresholdsFile <thresholdsFile>
                file containing custom regular expressions and thresholds.
        -summaryOnly
                Only print the class summaries, not the reports for individual hosts.
        -help
                this.

example:
        $0 -seekStateFile /tmp/.seekState

        ";

        exit 0;

}

if (scalar %::commandLineOptions) {
	$::commandLineReport = 1;
}

$::seekStateFile = exists $::commandLineOptions{seekStateFile} ?
        $::commandLineOptions{seekStateFile} : $::seekStateFile;

$::thresholdsStateFile = exists $::commandLineOptions{thresholdsStateFile} ?
        $::commandLineOptions{thresholdsStateFile} : $::thresholdsStateFile;

if (
	exists $::commandLineOptions{thresholdsFile}
		&&
	-r $::commandLineOptions{thresholdsFile}
) {
	require $::commandLineOptions{thresholdsFile};
}

#
# if we're not doing a command line report,
# register some bounds checking
#

unless (
	exists $::commandLineOptions{'summaryOnly'}
) {
	&registerAlarm(time + $::killTime, $::killSize, 10);
}

if (
	-f $::seekStateFile
	&&
	open(STATE,$::seekStateFile)
) {

	#
	# only one instance running at a time for the same seek state file
	# i.e. only one cron instance at a time,
	# but we can do a summary report without them stepping on each other.
	# 
	
	unless (
		flock(STATE,LOCK_EX|LOCK_NB)
	) {
		print "no flock for you!\n";
		exit 0;
	}

	local $/;
	no strict 'vars';
	%::seekState = %{ eval(<STATE>) };

}

if (
	-f $::thresholdsStateFile
	&&
	open(THRESHOLD,$::thresholdsStateFile)
) {

	local $/;
	no strict 'vars';
	%::thresholdsState = %{ eval(<THRESHOLD>) };

}

if (
	exists $::commandLineOptions{seekStateFileInitialize}
) {

	&seekStateFileInitialize;
	exit 0;
}

my %reportHash;

foreach my $class (sort keys %LogProcessing::Config::class) {

	my %lineHash;
	my %logHash;

	foreach my $glob (
		@{
			$LogProcessing::Config::class{$class}{'glob'}
		}
	) {

		foreach my $file (glob $glob) {

			$logHash{$file} = &reportLog(
				&readLog(\%lineHash, $class, $file),
				$class,
				1.1
			);

			my $convertedFile = "${class}_${file}";
                        $convertedFile =~ s#/#_#g;

			$logHash{$file}{'url'} = "${convertedFile}.html";

			unless (exists $::commandLineOptions{'summaryOnly'}) {

				open(REPORT, ">$logHash{$file}{'url'}");

				print REPORT &bbSendStatus(
					"$class $file",
					$logHash{$file}{'color'},
					$logHash{$file}{'summary'},
					$logHash{$file}{'status'},
				);

			}

			delete $logHash{$file}{'status'};
			delete $logHash{$file}{'summary'};

			close(REPORT);

		}
	}

	$reportHash{$class} = &reportLog(
		\%lineHash,
		$class,
		1.1
	);

	$reportHash{$class}{'url'} = "${class}.html";

	if (exists $::commandLineOptions{'summaryOnly'}) {

		print STDOUT &bbSendStatus(
			$class,
			$reportHash{$class}{'color'},
			$reportHash{$class}{'summary'},
			$reportHash{$class}{'status'}
		);

	} else {

		open(REPORT, ">$reportHash{$class}{'url'}");

		print REPORT &bbSendStatus(
			$class,
			$reportHash{$class}{'color'},
			$reportHash{$class}{'summary'},
			$reportHash{$class}{'status'},
			\%logHash
		);

		close(REPORT);
	
	}

	my $time = time;

	foreach my $line (keys %{ $reportHash{$class}{'topErrorsHash'} }) {

		++$::thresholdsState{$class}{$line}{'count'};
		$::thresholdsState{$class}{$line}{'time'} = $time;

		my $percent = ($reportHash{$class}{'topErrorsHash'}{$line} / $reportHash{$class}{'totalLines'}) * 100;
		$::thresholdsState{$class}{$line}{'total'} += $percent;

		unless (
			exists $::thresholdsState{$class}{$line}{'min'}
				&&
			($::thresholdsState{$class}{$line}{'min'} < $percent)
		) {
			$::thresholdsState{$class}{$line}{'min'} = $percent;
		}

		unless (
			exists $::thresholdsState{$class}{$line}{'max'}
				&&
			($::thresholdsState{$class}{$line}{'max'} > $percent)
		) {
			$::thresholdsState{$class}{$line}{'max'} = $percent;
		}

		 $::thresholdsState{$class}{$line}{'suggest'} = (
			(
				$::thresholdsState{$class}{$line}{'total'} / $::thresholdsState{$class}{$line}{'count'}
			) + $::thresholdsState{$class}{$line}{'max'}
		) / 2;
	}
}

#
# prune out old thresholds
#

$::thresholdretentionDate = time - $::thresholdretentionTime;
foreach my $class (keys %::thresholdsState) {
	foreach my $line (keys %{ $::thresholdsState{$class} }) {
		unless (
			exists $::thresholdsState{$class}{$line}{'time'} 
				&& 
			$::thresholdsState{$class}{$line}{'time'} >= $::thresholdretentionDate
		) { 
			delete $::thresholdsState{$class}{$line};
			#print Data::Dumper::Dumper $::thresholdsState{$class}{$line};
		}
	}
}

open(REPORT, ">index.html");

print REPORT &bbSendStatus(
	"Log Processing",
	"green",
	"",
	"",
	\%reportHash
);

close(REPORT);

open (STATE,">$::seekStateFile.$::lockString");
print STATE Data::Dumper::Dumper(\%::seekState);
close (STATE);
rename ("$::seekStateFile.$::lockString", $::seekStateFile);

open(THRESHOLDS, ">$::thresholdsStateFile.$::lockString");
print THRESHOLDS Data::Dumper::Dumper(\%::thresholdsState);
close(THRESHOLDS);
rename ("$::thresholdsStateFile.$::lockString", $::thresholdsStateFile);

sub readLog {

	my ($lineHashRef, $class, $file) = @_;

	unless (
		-f $file
			&&
		open(LOG, $file)
	) {

		unless(exists $::commandLineOptions{summaryOnly}) {
			print STDERR "unable to open file $file: $!";
		}

		next;

	}

	if (
		exists $::seekState{'filePosition'}{$file}
		&&
		-s $file >= $::seekState{'fileSize'}{$file}
	) {
		seek(LOG,$::seekState{'filePosition'}{$file},0);
	}

	my @lines = (<LOG>);
	$::seekState{'filePosition'}{$file} = tell(LOG);
	$::seekState{'fileSize'}{$file} = -s $file;
	close(LOG);

	chomp(@lines);

	my %uniqueLines;

	foreach my $transform (keys %{ $LogProcessing::Config::class{$class}{'transform'} }) {
		@lines = map {
			s/$transform/$LogProcessing::Config::class{$class}{'transform'}{$transform}/g;
			$_;
		} @lines;
	}

	foreach my $line (@lines) {
		if ($line =~ m/^\s*$/) { next; }

		++$uniqueLines{$line};
		++$$lineHashRef{$line};
	}

	$uniqueLines{""} = 0;
	$$lineHashRef{""} = 0;

	return \%uniqueLines;
}

foreach my $cluster (sort keys %::classLines) {
	foreach my $class (sort keys %{ $::classLines{$cluster} }) {
		delete $::classLines{$cluster}{$class}{""};
		&bbReport(
			$::classLines{$cluster}{$class}, $class,
			"$class,tmol,$cluster,websys,tmcs", 1.1
		);
	}
}

sub reportLog {
	my ($uniqueLinesRef, $class, $multiplier) = @_;

	my $status = "";
	my $summary = "ok";
	
	my $color = "green";

	my $totalLines = 0;

	foreach my $line (
		keys %{ $uniqueLinesRef }
	) {
		unless (defined $$uniqueLinesRef{$line}) {
			delete $$uniqueLinesRef{$line};
			next;
		}
		$totalLines += $$uniqueLinesRef{$line};
	}

	unless ($totalLines) {

		return {
			'color'		=>	'white',
			'summary'	=>	'no new log lines',
			'status'	=>	'',
			'topErrors'	=>	'',
		};
	
	}

	my @lines = keys %{ $uniqueLinesRef };

	# keep message percentages from freaking out under low volume

	if ($totalLines < 100 && $totalLines > 0) {
		$multiplier = $multiplier * (100 / $totalLines);
	}

	my %autoThresholdCount;
	my %uniqueUnknownLines;

	foreach my $line (@lines) {
		if (exists $::thresholdsState{$class}{$line}) {
			$autoThresholdCount{$line} += $$uniqueLinesRef{$line};							
		} else {
			$uniqueUnknownLines{$line} += $$uniqueLinesRef{$line};
		}
	}

	if (keys %autoThresholdCount) {

		my $matchedLines = 0;

		foreach my $line (keys %autoThresholdCount) {
			$matchedLines += $autoThresholdCount{$line};
		}

		$status .= sprintf(
			"\nMatched Errors (%d, %.2f%%)\n\n",
			$matchedLines,
			100 * $matchedLines / $totalLines,
		);
	}

	foreach my $line (
		sort { $autoThresholdCount{$b} <=> $autoThresholdCount{$a} } keys %autoThresholdCount
	) {

		unless (exists  $::thresholdsState{$class}{$line}{'suggest'}) {
			 $::thresholdsState{$class}{$line}{'suggest'} = 0;
		}

		my $suggest = $::thresholdsState{$class}{$line}{'suggest'} >= 2 ?
			$::thresholdsState{$class}{$line}{'suggest'} : 2;

		my $warn = ($suggest * $multiplier) / 100;
		my $panic = $warn + (.1 * $multiplier);
		my $localColor = "green";

		if ($autoThresholdCount{$line}/$totalLines >= $panic) {
			$color = "red";
			$localColor = "red";
			$summary = "**NOT** ok";
		}  else {
			if ($autoThresholdCount{$line}/$totalLines >= $warn) {
				unless ($color eq "red") { $color = "yellow"; }
				$localColor = "yellow";
				$summary = "NOT ok";
			}
		}

		# ugly hack

		my $frequency = $::thresholdsState{$class}{$line}{'count'} / 2500;
	
		my $frequencyString = "rare";
		if ($frequency > .5) {
			$frequencyString = "common";
		} elsif ($frequency > .33) {
			$frequencyString = "uncommon";
		}
		
		#$status .= sprintf(
		#	"&%s%5d%7.2f%% min %7.2f sug %7.2f max %7.2f count %4d warn %7.2f panic %7.2f %s\n", 
		#	$localColor,
		#	$autoThresholdCount{$line}, 
		#	100 * $autoThresholdCount{$line}/$totalLines,
		#	$::thresholdsState{$class}{$line}{'min'},
		#	$suggest,
		#	$::thresholdsState{$class}{$line}{'max'},
		#	$::thresholdsState{$class}{$line}{'count'},
		#	$warn * 100,
		#	$panic * 100,
		#	$line
		#);

		$status .= sprintf(
			"&%s%5d%7.2f%% &%-8s %s\n", 
			$localColor,
			$autoThresholdCount{$line}, 
			100 * $autoThresholdCount{$line}/$totalLines,
			$frequencyString,
			$line
		);
	}

	if (keys %uniqueUnknownLines) {

		my $unmatchedLines = 0;

		foreach my $line (keys %uniqueUnknownLines) {
			$unmatchedLines += $uniqueUnknownLines{$line}
		}

		$status .= sprintf(
			"\nUnmatched Errors (%d lines, %d unique errors, %.2f%%)\n\n",
			$unmatchedLines,
			scalar(keys %uniqueUnknownLines),
			100 * $unmatchedLines / $totalLines,
		);
	}

	my @uniqueUnknownLines = sort {
		$uniqueUnknownLines{$b} <=> $uniqueUnknownLines{$a}
	} keys %uniqueUnknownLines;

	foreach my $line (
		splice(	
			@uniqueUnknownLines,
			0,
			1000
		)
	) {

		my $warn = ($LogProcessing::Config::class{$class}{'warn'} * $multiplier) / 100;
		my $panic = $warn + (.1 * $multiplier);
		my $localColor = "green";

		if ($uniqueUnknownLines{$line}/$totalLines >= $panic) {
			$color = "red";
			$localColor = "red";
			$summary = "**NOT** ok";
		}  else {
			if ($uniqueUnknownLines{$line}/$totalLines >= $warn) {
				unless ($color eq "red") { $color = "yellow"; }
				$localColor = "yellow";
				$summary = "NOT ok";
			}
		}
		
		$status .= sprintf(
			"&%s%5d%7.2f%% %s\n", 
			$localColor,
			$uniqueUnknownLines{$line},
			100 * $uniqueUnknownLines{$line}/$totalLines,
			$line
		);
	}

	if (keys %{ $uniqueLinesRef }) {
		$status .= "\nTop Errors ($totalLines)\n\n";		
	}

	my @uniqueLines = sort {
		$$uniqueLinesRef{$b} <=> $$uniqueLinesRef{$a}
	} keys %{ $uniqueLinesRef };

	foreach my $line (
		@uniqueLines[0...19],
	) {

		unless (defined $line) { last; }

		$status .= sprintf(
			"%7d%7.2f%% %s\n", 
			$$uniqueLinesRef{$line}, 
			100 * $$uniqueLinesRef{$line}/$totalLines,
			$line
		);
	};

	my $topErrors = "";

	foreach my $line (
		@uniqueLines[0...4],
	) {

		unless (defined $line) { last; }

		$topErrors .= sprintf(
			"%7d%7.2f%% %s\n", 
			$$uniqueLinesRef{$line}, 
			100 * $$uniqueLinesRef{$line}/$totalLines,
			$line
		);
	};

	my %topErrorsHash;

	foreach my $line (
		@uniqueLines[0...39],
	) {

		unless (defined $line) { last; }

		$topErrorsHash{$line} = $$uniqueLinesRef{$line};

	};

	return {
		'color'		=>	$color,
		'summary'	=>	$summary,
		'status'	=>	$status,
		'topErrors'	=>	$topErrors,
		'totalLines'	=>	$totalLines,
		'topErrorsHash'	=>	\%topErrorsHash,
	};

}

sub bbSendStatus {
        my ($class, $color, $summary, $status, $fileHashRef) = @_;

        my $date = localtime(time);

	$status =~ s#<#&lt;#g;
	$status =~ s#>#&gt;#g;
	#$status =~ s#\&common#<span style="color: white">common</span>#g;
	$status =~ s#\&common#common#g;
	$status =~ s#\&uncommon#<span style="color: green">uncommon</span>#g;
	$status =~ s#\&rare#<span style="color: blue">rare</span>#g;
	$status =~ s#\&green#<span style="background-color: lightgreen">OK   </span>#g;
	$status =~ s#\&yellow(.*)#<span style="background-color: yellow">WARN $1</span>#g;
	$status =~ s#\&red(.*)#<span style="background-color: red">PANIC$1</span>#g;

#<body style="background-color:  black">
#<span style="color: black; font-weight: bold">
	my $output = qq{
<head>
<meta http-equiv="refresh" content="60">
<meta http-equiv="expires" content="Sat, 01 Jan 2001 00:00:00 GMT">
</head>
<pre>
<span style="font-weight: bold">$class $color $date $summary</span>
$status
	};

	my %outputColor;

	if ($fileHashRef) {
		foreach my $file (
			sort keys %{
				$fileHashRef
			}
		) {
			my $color = $$fileHashRef{$file}{'color'};

			if ($$fileHashRef{$file}{'color'} eq "green") { $$fileHashRef{$file}{'color'} = "lightgreen"; }
			$$fileHashRef{$file}{'topErrors'} =~ s#<#&lt;#g;
			$$fileHashRef{$file}{'topErrors'} =~ s#>#&gt;#g;
			$outputColor{$color} .= qq|
<a href="$$fileHashRef{$file}{'url'}"><span style="background-color: $$fileHashRef{$file}{'color'}">$file</span></a>
$$fileHashRef{$file}{'topErrors'}|;
		}
	}

	foreach my $color ('red', 'yellow', 'green', 'white') {
		if (exists $outputColor{$color}) {
			$output .= $outputColor{$color};
		}
	}

	$output .= qq{
</pre>
</span>
</body>
	};

	if ($::commandLineReport) {
		return $output;
	} else {
		return $output;
	}
}

sub seekStateFileInitialize {

	foreach my $class (keys %LogProcessing::Config::class) {
		foreach my $glob (
			@{
				$LogProcessing::Config::class{$class}{'glob'}
			}
		) {

			foreach my $file (glob $glob) {
				unless (
					-f $file
						&&
					open(LOG, $file)
				) {
					unless(exists $::commandLineOptions{summaryOnly}) {
						print STDERR "unable to open file $file: $!";
					}

					next;
				}

				seek(LOG, 0, 2);
				$::seekState{'filePosition'}{$file} = tell(LOG);
				$::seekState{'fileSize'}{$file} = -s $file;
				close(LOG);
			}
		}
	}

	open (STATE,">$::seekStateFile.$::lockString");
	print STATE Data::Dumper::Dumper(\%::seekState);
	close (STATE);
	rename ("$::seekStateFile.$::lockString", $::seekStateFile);

}

sub registerAlarm {
	my ($killTime,$killSize,$checkFrequency) = @_;

	$SIG{ALRM} = sub {

		$SIG{ALRM} = "IGNORE";

		#
		# linux specific memory check
		#

		open(STATM, "/proc/self/statm");
		my ($size) = split(/\s/, scalar <STATM>);
		close(STATM);

		my $error;

		if (time >= $killTime) { $error = "log processing time exceeded"; }
		if ($size >= $killSize) { $error = "log processing memory exceeded (${size}k)"; }
	
		if ($error) {
			&seekStateFileInitialize;

			if (-f "$::seekStateFile.$::lockString") {
				unlink("$::seekStateFile.$::lockString");
			}

			if (-f "$::thresholdsStateFile.$::lockString") {
				unlink ("$::thresholdsStateFile.$::lockString");
			}

			die "ERROR: $error";
		}

		&registerAlarm($killTime,$killSize,$checkFrequency);
	};
	alarm($checkFrequency);

}
