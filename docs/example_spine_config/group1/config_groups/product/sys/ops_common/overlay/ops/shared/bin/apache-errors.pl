package LogProcessing::Config;

%genericApacheRegexp = (

	'child pid .* exit signal Segmentation fault \(11\)', 0,
	'could not make child process .* exit, attempting to continue anyway', 0,
	'child process .* still did not exit, sending a SIGKILL', 1,

	#'Attempt to serve directory', 1,
	#'request failed: error reading the headers', 1,
	#'server reached MaxClients setting', 5,
	#'configured -- resuming normal operations', 5,
	#'caught SIGTERM, shutting down', 5,
	#'Unclean shutdown of previous Apache run', 5,
);

%genericRegexp = (
	'ipAddress'		=>	'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b',
	'timeStamp_apache'	=>	'\w{3}\s+\w{3}\s+\d{1,2}\s+\d{1,2}:\d{1,2}:\d{1,2}\s+\d{4}',
	'sessionId'		=>	'\S+',
);

%genericTransforms = (

	'ipAddress'	=>	[
		'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
			=>	'(ip address)?.*',
	],

	'eventId'	=>	[
		'\b[0-9A-F]{12,15}\b'					
			=>	'(*BAD* event id, too short)?.*',
		'\b[0-9A-F]{16}\b'						
			=>	'(event id)?.*',
		'\b[0-9A-F]{17,}\b'						
			=>	'(*BAD* event id, too long)?.*',
	],

	
	'eventLog'	=>	[
		'\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -\d{4}\]\s+(\d+|-)\s+'
			=>	'',
		'\/\S{86}\s'
			=>	'(vstring)?.* ',
		'\s+\S+\s+\d+\s+\S+\s+pid\S+\s+(\d+|-)\s+'
			#=>	' (unique id)?.* (event idx)?.* (session id)?.* (browser id)?.* (member id)?.* ',
			=>	' ',
	],

	'apache'	=>	[
		'\[\w{3}\s+\w{3}\s+\d{1,2}\s+\d{1,2}:\d{1,2}:\d{1,2}\s+\d{4}\]'
			=>      '',
		'\[(error|notice)\]'
			=>	'',
		'\(\d+\) Apache::SizeLimit httpd process too big, exiting at SIZE=\d+\s+KB\s+SHARE=\d+\s+KB\s+REQUESTS=\d+\s+LIFETIME=\d+\s+seconds'
			=>	'(pid)?.* Apache::SizeLimit httpd process too big, exiting at SIZE=\d+ KB  SHARE=\d+ KB  REQUESTS=\d+  LIFETIME=\d+ seconds',
		'child process \d+'
			=>	'child process (pid)?.*',
		'child pid \d+'
			=>	'child pid (pid)?.*',
	],

	'apacheAccess'	=>	[
		'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}\]'
			=>	'',
		'(?<=\" \d\d\d ).*'
			=> '',
		'\?\S+'
			=> '?(query)?',
	],

	'mysql'		=>	[
		'\b\d{6} \d{2}:\d{2}:\d{2}\b'
			=>	'(time stamp)?.*'
	],

	'sessionId'	=>	[
		'\[[^\]]{24}\]'	
			=>	'',
		'\b[0-9a-f]{30,}\b'
			=>	'(session id)?.*',
	],

	'browserId'		=>	[
		'\bpid\S+\b'	
			=>	'(browser id)?.*',
	],

	'orderId'		=>	[
		'\b\d{1,2}-\d\d\d\d\d\/[0-9A-Z]{3}\b'
			=>	' (order id)?.* ',
	],

	'cache'			=>	[
		' PUT /\S+ '	
			=>	' PUT .* ',
		' GET /\S+ '	
			=>	' GET .* ',
		' HEAD /\S+ '	
			=>	' HEAD .* ',
	],

	'syslog'		=>	[
		'\[\d+\]'	=>	'(pid)?.*',
		'\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}'	=>	'(date)?.*',
	],

	'tmHostname'		=>	[
		'\b\w{3,}\d+\.\w{3,}\.\w{3,}\d+(\.\w{3,}\.tmcs)?\b'	=>	'(tm hostname)?.*',
	],

	'fileOrDirectory'		=>	[
		'\/?\w+\/[\w\/]+'	=>	'(file or directory)?.*',
	],

	'ntf'		=>	[
		'NTF::Log::Trace::\s+\d+\b'
			=>	'NTF::Log::Trace::\s+\d+',
		'NTF::XML\s+\d+\b'
			=>	'NTF::XML\s+\d+',
		'NTF::Resources\s+\d+\b'
			=>	'NTF::Resources\s+\d+',
	],

	'rsync'				=>	[
		'rsync pid=\d+'
			=>	'rsync pid=(pid)?.*',
		'wrote \d+ bytes  read \d+ bytes  total size \d+'
			=>	'wrote \d+ bytes  read \d+ bytes  total size \d+',
	],

	'perl'		=>	[
		'ARRAY\(0x[0-9a-f]+\)'
			=>	'(array reference)?.*',
		'HASH\(0x[0-9a-f]+\)'
			=>	'(hash reference)?.*',
	],

	'statcl'	=>	[
		'statcl: \.\d+,[0-9a-f]+:[0-9a-f]+, '
			=> 'statcl: (statcl crap)?.* ',
		' BIND, \d+'
			=> ' BIND, \d+',
		' CONNECT, \d+'
			=> ' CONNECT, \d+',
		' RECV, \d+'
			=> ' RECV, \d+',
		' SEND, \d+'
			=> ' SEND, \d+',
	],
);
	
#$class{'apache_access_pxy'} = {
#
#	'warn'		=>	2,
#	'panic'		=>	10,
#
#	'glob'		=>	[
#		'/*/vol*/*-*-tmol-pxy/*/logs/access_log'
#	],
#
#	'transform'	=>	{
#		'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}'	=>	'',
#	},
#
#	'regexp'	=>	{
#		%genericApache,
#	},
#};

$class{'apache_error_websys_amgr_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-app/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'\[client \d+\.\d+\.\d+\.\d+\]'
			=>	'',
		', referer: .*'
			=>	'',
	},

};

$class{'syslog_local_websys_amgr_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-app/*/logs/local_syslog'
	],

	'transform'	=>	{
		@{ $genericTransforms{'syslog'} },
		@{ $genericTransforms{'tmHostname'} },
		@{ $genericTransforms{'ipAddress'} },
		#'\?\S+'
		#	=> '?(query)?',
		'\[\d+-\d+\]'
			=> '?(diget-diget)',
		#'\S+\|[\|\S]+'
		#	=> '?(pipe-strings)',
	},

};

$class{'apache_access_accountmanager_websys_amgr_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-app/*/logs/accountmanager_log'
	],

	'transform'	=>	{
		'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}\]'
			=>	'',
		'(?<=\" \d\d\d ).*'
			=> '',
		'\?\S+'
			=> '?(query)?',
	},

};

$class{'apache_access_teamexchange_websys_amgr_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-app/*/logs/teamexchange_log'
	],

	'transform'	=>	{
		'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}\]'
			=>	'',
		'(?<=\" \d\d\d ).*'
			=> '',
		'\?\S+'
			=> '?(query)?',
	},

};

$class{'apache_access_accountmanager_websys_amgr_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-mgr/*/logs/accountmanager_log'
	],

	'transform'	=>	{
		'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}\]'
			=>	'',
		'(?<=\" \d\d\d ).*'
			=> '',
		'\?\S+'
			=> '?(query)?',
	},

};

$class{'apache_access_teamexchange_websys_amgr_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-mgr/*/logs/teamexchange.log'
	],

	'transform'	=>	{
		'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+-\s+-\s+\[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} -?\d{4}\]'
			=>	'',
		'(?<=\" \d\d\d ).*'
			=> '',
		'\?\S+'
			=> '?(query)?',
	},

};

$class{'apache_error_websys_amgr_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-mgr/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'\[client \d+\.\d+\.\d+\.\d+\]'
			=>	'',
		', referer: .*'
			=>	'',
	},

};

$class{'syslog_local_websys_amgr_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-mgr/*/logs/local_syslog'
	],

	'transform'	=>	{
		@{ $genericTransforms{'syslog'} },
		@{ $genericTransforms{'tmHostname'} },
		@{ $genericTransforms{'ipAddress'} },
	},

};

$class{'apache_error_websys_amgr_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-amgr-mgr/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'\[client \d+\.\d+\.\d+\.\d+\]'
			=>	'',
		', referer: .*'
			=>	'',
	},

};

$class{'apache_error_websys_amgr_pxy'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/websys-*-amgr-pxy/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'\[client \d+\.\d+\.\d+\.\d+\]'
			=>	'',
		', referer: .*'
			=>	'',
	},

};

$class{'apache_error_pos_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol**/*-*-pos-app/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'browserId'} },
		'\(sid:\S{24}\):'
			=>	'(sid)?.*',
		'\"sid\":\"\S{24}\"'
			=>	'"sid":(sid)?.*',
		'\w{3}\s+\w{3}\s+\d{1,2}\s+\d{1,2}:\d{1,2}:\d{1,2}\s+\d{4}'
			=>      '',
	},

};

$class{'strfwd_pos_mgr'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol**/*-*-pos-mgr/*/log/strfwd.log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
	},

};

$class{'apache_error_shared_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-shared-app/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
	},

};

$class{'apache_error_shared_cch'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-shared-cch/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'Session\S{24}\s'
			=>	'Session(session id)?.* ',
	},

};

$class{'apache_error_shared_pxa'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-shared-pxa/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
	},

};

$class{'apache_error_shared_pxy'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-shared-pxy/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
	},

};

$class{'apache_error_shared_tls'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-shared-tls/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
	},

};

$class{'apache_error_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-app/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'sessionId'} },
		@{ $genericTransforms{'eventId'} },
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'cache'} },
		@{ $genericTransforms{'perl'} },
		'Venue ID \d+\b'
			=>	'Venue ID \d+',
		'Invalid Event ID passed to controler: .* in /app/shared/lib/perl/TM/Control/Event.pm', 
			=>	'Invalid Event ID passed to controler: .* in /app/shared/lib/perl/TM/Control/Event.pm',
		'no data received: [^;]+;'
			=>	'no data received: (atlas transaction information)?.*',
		'\d+ seconds'
			=>	'\d+ seconds',
		'member \d+\b',
			=>	'member (member id)?.*',
	},

};

$class{'apache_error_apt'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-apt/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'browserId'} },
		@{ $genericTransforms{'sessionId'} },
		@{ $genericTransforms{'eventId'} },
		@{ $genericTransforms{'orderId'} },
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'cache'} },
		@{ $genericTransforms{'perl'} },
		'AuctionBatch\{[^\}]+\}'
			=>	'AuctionBatch{.*}',
		'Attempted: [^,]+, category: \d+, campaign: \d+'
			=>	'Attempted: .* category: .* campaign: .*',
		'\[for statement [^\]]+\]'	
			=>	'(oracle statement)?.*',
		'member \d+\b',
			=>	'member (member id)?.*',
		'mid \(\d+\)'
			=>	'mid (member id)?.*',
		'method \d+'
			=>	'method (method id)?.*',
		'method id \d+'
			=>	'method id (method id)?.*',
		'host assignment id \d+'
			=>	'host assignment id (host assignment id)?.*',
		'host assignment id: \d+'
			=>	'host assignment id (host assignment id)?.*',
	},

};

$class{'apache_error_apx'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-apx/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'sessionId'} },
		@{ $genericTransforms{'eventId'} },
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'cache'} },
		@{ $genericTransforms{'perl'} },
	},

};

$class{'apache_error_cch'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-cch/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'eventId'} },
		@{ $genericTransforms{'perl'} },
		@{ $genericTransforms{'apache'} },
		'=[^\s\(\)\&]+[\s\&$]'
			=>	'=.*',
		'\/\d{4,}\b'
			=>	'/\d+',
		'Session\S{24}\s'
			=>	'Session(session id)?.* ',
		'\b[0-9a-f]{32}\b'
			=>	'(short semaphore)?.*',
		'\b[0-9A-F]{56}\b'
			=>	'(long semaphore)?.*',
		#'\/\d+\b'
		#	=>	'/\d+',
		#'\b\w{80}\b'
		#	=>	'(vstring)?.*',
		#'\b[0-9A-F]{56}\b'
		#	=>	'(long semaphore)?.*',
		#'[?&]\w+=[?&\s]'
		#	=>	'(empty key)?.*'
	},

};

$class{'apache_error_nta'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-nta/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'ntf'} },
	},

};

$class{'apache_error_pwd'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-pwd/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'ipAddress'} },
	},

};

$class{'apache_error_pwq'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-pwq/*/logs/error_log'
	],

	#
	# lots and lots of guessing
	#

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'ipAddress'} },
		'mod_qfanclub: XML has \d+ chunks, total size \d+ XML\['
			=>	'mod_qfanclub: XML has \d+ chunks, total size \d+ XML\[',
		'\[\d+\]'
			=>	'[\d+]',
		'>\d+<'
			=>	'>\d+<',
		'Password\[[^\]]+\]'
			=>	'Password[.*]',
		'<T:primary_password>[^>]+</T:primary_password>',
			=>	'<T:primary_password>.*</T:primary_password>',
		'\d+ byte'
			=>	'\d+ byte',
	},

};

$class{'apache_error_pxy'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-pxy/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'eventId'} },
		'\[client \d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\]'
			=>	'',
		', referer: .*'	
			=>	'',
		'semaphore expired for \S{24} on server'
			=>	'semaphore expired for (semaphore)?.* on server',
		'/checkout/reserve/\S{86}'
			=>	'/checkout/reserve/\S{86}',
		'\[unique_id ".{24}"\]'
			=>      '',
		'\[uri ".*?"\]',
			=>	'', 
		#'\[id "960015"\] \[msg "Request Missing an Accept Header"\].*'
		#	=>	[id "960015"] [msg "Request Missing an Accept Header"]',
	},

};

$class{'apache_error_ses'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-ses/*/logs/error_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'apache'} },
		'Session\S{24}\s'
			=>	'Session(session id)?.* ',
		'\b[0-9a-f]{32}\b'
			=>	'(short semaphore)?.*',
		'\b[0-9A-F]{56}\b'
			=>	'(long semaphore)?.*',
	},

};

$class{'apache_event_app'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-app/*/logs/event_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'eventLog'} },
		$genericRegexp{'ipAddress'}
			=>	'',
		'//+'
			=>	'(multiple slashes, somebody is fucking with us)?.*',
		'email_address=\S+'
			=>	'email_address=.*',
	},

};

$class{'apache_event_apt'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-apt/*/logs/event_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'eventLog'} },
		$genericRegexp{'ipAddress'}
			=>	'',
		'attempt=.*\s+valid=.*'
			=>	'attempt=.* valid=.*',
		'email_address=\S+'
			=>	'email_address=.*',
		'\/event\/\S+'
			=>	'\/event\/(event id and args)?.*',
	},

};

$class{'apache_event_apx'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-apx/*/logs/event_log'
	],

	'transform'	=>	{
		@{ $genericTransforms{'eventLog'} },
		$genericRegexp{'ipAddress'}
			=>	'',
	},

};

$class{'mysql_error_edb'} = {

	'warn'		=>	0,
	'panic'		=>	0,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-edb/*/mysql/data/*.err'
	],

	'transform'	=>	{
		@{ $genericTransforms{'mysql'} },
	},

};

$class{'mysql_error_sdb'} = {

	'warn'		=>	0,
	'panic'		=>	0,

	'glob'		=>	[
		'/*/vol*/*-*-tmol-sdb/*/mysql/data/*.err'
	],

	'transform'	=>	{
		@{ $genericTransforms{'mysql'} },
	},

};

$class{'syslog_messages'} = {

	'warn'		=>	2,
	'panic'		=>	10,

	'glob'		=>	[
		'/var/log/messages'
	],

	'transform'	=>	{
		@{ $genericTransforms{'ipAddress'} },
		@{ $genericTransforms{'syslog'} },
		@{ $genericTransforms{'tmHostname'} },
		@{ $genericTransforms{'fileOrDirectory'} },
		@{ $genericTransforms{'ntf'} },
		@{ $genericTransforms{'rsync'} },
		@{ $genericTransforms{'statcl'} },
		'port \d+'
			=>	'port (port)?.*',
		'Applied release \"\d+\" at .*'
			=> 'Applied release (release)?.* at (date)?.*',
	},

};

1;
