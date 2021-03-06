package DDGC;
# ABSTRACT: DuckDuckGo Community Platform

use Moose;

use DDGC::Config;
use DDGC::DB;
use DDGC::DuckPAN;
use DDGC::XMPP;
use DDGC::Markup;
use DDGC::Envoy;
use DDGC::Postman;
use DDGC::Forum;
use DDGC::Util::DateTime;

use File::Copy;
use IO::All;
use File::Spec;
use File::ShareDir::ProjectDistDir;
use Net::AIML;
use Text::Xslate qw( mark_raw );
use Class::Load qw( load_class );
use POSIX;
use Cache::FileCache;
use Cache::NullCache;
use namespace::autoclean;
use LWP::UserAgent;

our $VERSION ||= '0.000';

##############################################
# TESTING AND DEVELOPMENT, NOT FOR PRODUCTION
sub deploy_fresh {
	my ( $self ) = @_;

	die "ARE YOU INSANE????? KILLING LIVE???? GO FUCK YOURSELF!!!" if $self->is_live;

	$self->config->rootdir();
	$self->config->filesdir();
	$self->config->cachedir();

	$self->db->deploy;
	$self->db->resultset('User::Notification::Group')->update_group_types;
}
##############################################

####################################################################
#   ____             __ _                       _   _
#  / ___|___  _ __  / _(_) __ _ _   _ _ __ __ _| |_(_) ___  _ __
# | |   / _ \| '_ \| |_| |/ _` | | | | '__/ _` | __| |/ _ \| '_ \
# | |__| (_) | | | |  _| | (_| | |_| | | | (_| | |_| | (_) | | | |
#  \____\___/|_| |_|_| |_|\__, |\__,_|_|  \__,_|\__|_|\___/|_| |_|
#                         |___/

has config => (
	isa => 'DDGC::Config',
	is => 'ro',
	lazy_build => 1,
	handles => [qw(
		is_live
		is_view
	)],
);
sub _build_config { DDGC::Config->new }
####################################################################

has http => (
    isa => 'LWP::UserAgent',
    is => 'ro',
    lazy_build => 1,
);
sub _build_http {
    my $ua = LWP::UserAgent->new;
    $ua->timeout(5);
    my $agent = (ref $_[0] ? ref $_[0] : $_[0]).'/'.$VERSION;
    $ua->agent($agent);
    return $ua;
}

############################################################
#  ____        _    ____            _
# / ___| _   _| |__/ ___| _   _ ___| |_ ___ _ __ ___  ___
# \___ \| | | | '_ \___ \| | | / __| __/ _ \ '_ ` _ \/ __|
#  ___) | |_| | |_) |__) | |_| \__ \ ||  __/ | | | | \__ \
# |____/ \__,_|_.__/____/ \__, |___/\__\___|_| |_| |_|___/
#                         |___/

# Database (DBIx::Class)
has db => (
	isa => 'DDGC::DB',
	is => 'ro',
	lazy_build => 1,
	handles => [qw(
		without_events
	)],
);
sub _build_db { DDGC::DB->connect(shift) }
sub resultset { shift->db->resultset(@_) }
sub rs { shift->resultset(@_) }

# XMPP access interface
has xmpp => (
	isa => 'DDGC::XMPP',
	is => 'ro',
	lazy_build => 1,
);
sub _build_xmpp { DDGC::XMPP->new({ ddgc => shift }) }

# Markup Text parsing
has markup => (
	isa => 'DDGC::Markup',
	is => 'ro',
	lazy_build => 1,
);
sub _build_markup { DDGC::Markup->new({ ddgc => shift }) }

# Notification System
has envoy => (
	isa => 'DDGC::Envoy',
	is => 'ro',
	lazy_build => 1,
);
sub _build_envoy { DDGC::Envoy->new({ ddgc => shift }) }

# Mail System
has postman => (
	isa => 'DDGC::Postman',
	is => 'ro',
	lazy_build => 1,
	handles => [qw(
		mail
	)],
);
sub _build_postman { DDGC::Postman->new({ ddgc => shift }) }

# Access to the DuckPAN infrastructures (Distribution Management)
has duckpan => (
	isa => 'DDGC::DuckPAN',
	is => 'ro',
	lazy_build => 1,
);
sub _build_duckpan { DDGC::DuckPAN->new({ ddgc => shift }) }

has cache => (
	isa => 'Cache::Cache',
	is => 'ro',
	lazy_build => 1,
);
sub _build_cache {
	return $_[0]->config->no_cache
		? Cache::NullCache->new
		: Cache::FileCache->new({
				namespace => 'DDGC',
				cache_root => $_[0]->config->cachedir,
			});
}

##############################
# __  __    _       _
# \ \/ /___| | __ _| |_ ___
#  \  // __| |/ _` | __/ _ \
#  /  \\__ \ | (_| | ||  __/
# /_/\_\___/_|\__,_|\__\___|
# (Templating SubSystem)
#

has xslate => (
	isa => 'Text::Xslate',
	is => 'ro',
	lazy_build => 1,
);
sub _build_xslate {
	my $self = shift;
	my $xslate;
	my $obj2dir = sub {
		my $obj = shift;
		my $class = $obj->can('i') ? $obj->i : ref $obj;
		if ($class =~ m/^DDGC::DB::Result::(.*)$/) {
			my $return = lc($1);
			$return =~ s/::/_/g;
			return $return;
		}
		if ($class =~ m/^DDGC::DB::ResultSet::(.*)$/) {
			my $return = lc($1);
			$return =~ s/::/_/g;
			return $return.'_rs';
		}
		if ($class =~ m/^DDGC::Web::(.*)/) {
			my $return = lc($1);
			$return =~ s/::/_/g;
			return $return;
		}
		die "cant include ".$class." with i-function";
	};
	my $i_template_and_vars = sub {

		my $object = shift;
		my $subtemplate;
		my $no_templatedir;
		my $vars;
		if (ref $object) {
			$subtemplate = shift;
			$vars = shift;
		} else {
			$no_templatedir = 1;
			$subtemplate = $object;
			my $next = shift;
			if (ref $next eq 'HASH') {
				$object = undef;
				$vars = $next;
			} else {
				$object = $next;
				$vars = shift;
			}
		}
		my $main_object;
		my @objects;
		push @objects, $object if $object;
		if (ref $object eq 'ARRAY') {
			$main_object = $object->[0];
			@objects = @{$object};
		} else {
			$main_object = $object;
		}
		my %current_vars = %{$xslate->current_vars};
		my $no_caller = delete $vars->{no_caller} ? 1 : 0;
		if (defined $current_vars{_} && !$no_caller) {
			$current_vars{caller} = $current_vars{_};
		}
		$current_vars{_} = $main_object;
		my $ref_main_object = ref $main_object;
		if ($main_object && $ref_main_object) {
			if ($main_object->can('meta')) {
				for my $method ( $main_object->meta->get_all_methods ) {
					if ($method->name =~ m/^i_(.*)$/) {
						my $name = $1;
						my $var_name = '_'.$name;
						my $func = 'i_'.$name;
						$current_vars{$var_name} = $main_object->$func;
					}
				}
			}
		}
		my @template = ('i');
		unless ($no_templatedir) {
			push @template, $obj2dir->($main_object);
		}
		push @template, $subtemplate ? $subtemplate : 'label';
		my %new_vars;
		for (@objects) {
			my $obj_dir = $obj2dir->($_);
			if (defined $new_vars{$obj_dir}) {
				if (ref $new_vars{$obj_dir} eq 'ARRAY') {
					push @{$new_vars{$obj_dir}}, $_;
				} else {
					$new_vars{$obj_dir} = [
						$new_vars{$obj_dir}, $_,
					];
				}
			} else {
				$new_vars{$obj_dir} = $_;
			}
		}
		for (keys %new_vars) {
			$current_vars{$_} = $new_vars{$_};
		}
		if ($vars) {
			for (keys %{$vars}) {
				$current_vars{$_} = $vars->{$_};
			}
		}
		return join('/',@template).".tx",\%current_vars;
	};
	$xslate = Text::Xslate->new({
		path => [$self->config->templatedir],
		cache_dir => $self->config->xslate_cachedir,
		suffix => '.tx',
		function => {

			# Functions to access the main model and some functions specific
			d => sub { $self },

			# Mark text as raw HTML
			r => sub { mark_raw(@_) },

			# trick function for DBIx::Class::ResultSet
			results => sub {
				my ( $rs, $sorting ) = @_;
				my @results = $rs->all;
				$sorting
					? [ sort { $b->$sorting <=> $a->$sorting } @results ]
					: [ @results ];
			},

			# general functions avoiding xslates problems
			call => sub {
				my $thing = shift;
				my $func = shift;
				$thing->$func;
			},
			call_if => sub {
				my $thing = shift;
				my $func = shift;
				$thing->$func if $thing;
			},
			replace => sub {
				my $source = shift;
				my $from = shift;
				my $to = shift;
				$source =~ s/$from/$to/g;
				return $source;
			},
			urify => sub { lc(join('-',split(/\s+/,join(' ',@_)))) },

			floor => sub { floor($_[0]) },
			ceil => sub { ceil($_[0]) },

			# simple helper for userpage form management
			upf_view => sub { 'userpage/'.$_[1].'/'.$_[0]->view.'.tx' },
			upf_edit => sub { 'my/userpage/field/'.$_[0]->edit.'.tx' },
			#############################################

			# Duration display helper mapped, see DDGC::Util::DateTime
			dur => sub { dur(@_) },
			dur_precise => sub { dur_precise(@_) },
			#############################################

			i_template_and_vars => $i_template_and_vars,
			i => sub { mark_raw($xslate->render($i_template_and_vars->(@_))) },
			i_template => sub {
				my ( $template, $vars ) = $i_template_and_vars->(@_);
				return $template
			},

			results_event_userlist => sub {
				my %users;
				for ($_[0]->all) {
					if ($_->event->users_id) {
						unless (defined $users{$_->event->users_id}) {
							$users{$_->event->users_id} = $_->event->user;
						}
					}
				}
				return [values %users];
			},

			style => sub {
				my %style;
				my @styles = @_;
				while (@styles) {
					my $t_style = $self->template_styles->{shift @styles};
					if (ref $t_style eq 'HASH') {
						$style{$_} = $t_style->{$_} for keys %{$t_style};
					} elsif (ref $t_style eq 'ARRAY') {
						unshift @styles, @{$t_style};
					}
				}
				my $return = 'style="';
				$return .= $_.':'.$style{$_}.';' for (keys %style);
				$return .= '"';
				return mark_raw($return);
			},

			username_gimmick => sub {
				mark_raw(substr($_[0],0,-2).'<i>'.substr($_[0],-2).'</i>')
			},

		},
	});
	return $xslate;
}

sub template_styles {{
	'default' => {
		'font-family' => 'sans-serif',		
	},
	'sub_text' => {
		'font-family' => 'sans-serif',
		'font-size' => '12px', 
	},
	'signoff' => {
		'color' => '#999999',
	},
	'warning' => {
		'font-family' => 'sans-serif',
		'font-style' => 'normal',
		'font-size' => '11px', 
		'color' => '#a8a8a8',
	},
	'site_title' => {
		'font-family' => 'sans-serif',
		'position' => 'relative',
		'text-align' => 'left',		
		'line-height' => '1',
		'margin' => '0',
	},
	'site_maintitle' => {
		'font-weight' => 'bold',
		'font-size' => '21px',
		'padding-top' => '10px',
		'left' => '-1px',		
	},
	'green' => {
		'font-style' => 'normal',
		'color' => '#48af04',
	},
	'site_subtitle' => {
		'font-weight' => 'normal',
		'color' => '#a0a0a0',		
		'padding-top' => '4px',
		'padding-bottom' => '7px',
		'font-size' => '12px',		
	},
	'msg_body' => {		
		'border' => '1px solid #d7d7d7',
		'border-radius' => '5px',
		'max-width' => '800px',
	},
	'msg_header' => {
		'width' => '100%',
		'background-color' => '#f1f1f1',
		'border-bottom' => '1px solid #d7d7d7',
		'border-radius' => '5px 5px 0 0',		
	},
	'msg_title' => {
		'font-family' => 'sans-serif',
		'font-weight' => 'normal',
		'font-size' => '28px',
		'color' => '#a0a0a0',	
		'margin' => '0',
		'padding' => '9px 0',
	},	
	'msg_content' => {
		'font-family' => 'sans-serif',
		'padding' => '10px 0', 
		'background-color' => '#ffffff',
	},
	'msg_notification' => {
		'font-family' => 'sans-serif',
		'padding' => '0', 		
		'background-color' => '#ffffff',		
	},
	'notification' => {
		'padding' => '10px 0',
		'font-family' => 'sans-serif',
		'width' => '100%',
		'border-bottom' => '1px solid #d7d7d7',	
	},
	'notification_text' => {
		'font-family' => 'sans-serif',
		'font-size' => '14px',
	},
	'notification_icon' => {
		'width' => '40px',
		'height' => '40px',
		'outline' => 'none',
		'border' => 'none',
	},
	'notification_count' => {
		'padding' => '5px 0',
		'background-color' => '#fbfbfb',
		'font-family' => 'sans-serif',
		'width' => '100%',
		'border-bottom' => '1px solid #d7d7d7',	
	},
	'notification_count_text' => {
		'margin' => '0',
		'padding-top' => '4px',
		'color' => '#a0a0a0',
		'font-weight' => 'bold',
		'font-size', => '16px',
	},	
	'button' => {
		'font-family' => 'sans-serif',
		'font-size' => '14px',
		'border-radius' => '3px',
		'display' => 'block',		
		'padding' => '0 12px',
		'height' => '28px',
		'line-height' => '28px',		
		'text-align' => 'center',
		'text-decoration' => 'none',
		'color' => '#d7d7d7',
		'background-color' => '#ffffff',
		'border' => '1px solid #d7d7d7',
		'white-space' => 'nowrap',
	},
	'button_blue' => {
		'color' => '#4b8df8',		
		'border-color' => '#4b8df8',
	},
	'button_green' => {
		'color' => '#48af04',		
		'border-color' => '#48af04',
	},
	'view_link' => {
		'color' => '#d7d7d7',
		'font-size' => '60px',
		'display' => 'block',
		'text-align' => 'right',
		'text-decoration' => 'none',
		'line-height' => '35px',
		'height' => '40px',
		'overflow' => 'visible',	
	},
}}

##############################

##################################################
#  ____       _           ____             _
# |  _ \ ___ | |__   ___ |  _ \ _   _  ___| | __
# | |_) / _ \| '_ \ / _ \| | | | | | |/ __| |/ /
# |  _ < (_) | |_) | (_) | |_| | |_| | (__|   <
# |_| \_\___/|_.__/ \___/|____/ \__,_|\___|_|\_\

has roboduck => (
    isa => 'Net::AIML',
    is => 'ro',
    lazy_build => 1,
);
sub _build_roboduck {
    my ( $self ) = @_;
    Net::AIML->new( botid => $self->config->roboduck_aiml_botid );
}
##################################################

has forum => (
    isa => 'DDGC::Forum',
    is => 'ro',
    lazy_build => 1,
);
sub _build_forum { DDGC::Forum->new( ddgc => shift ) }

#
# ======== User ====================
#

sub update_password {
	my ( $self, $username, $new_password ) = @_;
	return unless $self->config->prosody_running;
	$self->xmpp->admin_data_access->put(lc($username),'accounts',{ password => $new_password });
}

sub delete_user {
	my ( $self, $username ) = @_;
	my $user = $self->db->resultset('User')->single({
		username => $username,
	});
	if ($user) {
		my $deleted_user = $self->db->resultset('User')->single({
			username => $self->config->deleted_account,
		});
		die "Deleted user account doesn't exist!" unless $deleted_user;
		die "You can't delete the deleted account!" if $deleted_user->username eq $user->username;
		my $guard = $self->db->txn_scope_guard;
		if ($self->config->prosody_running) {
			$self->xmpp->_prosody->_db->resultset('Prosody')->search({
				host => $self->config->prosody_userhost,
				user => $username,
			})->delete;
		}
		my @translations = $user->token_language_translations->search({})->all;
		for (@translations) {
			$_->username($deleted_user->username);
			$_->update;
		}
		my @translated_token_languages = $user->token_languages->search({})->all;
		for (@translated_token_languages) {
			$_->translator_users_id($deleted_user->id);
			$_->update;
		}
		my @checked_translations = $user->checked_translations->search({})->all;
		for (@checked_translations) {
			$_->check_users_id($deleted_user->id);
			$_->update;
		}
		my @comments = $user->comments->search({})->all;
		for (@comments) {
			$_->content("This user account has been deleted.");
			$_->users_id($deleted_user->id);
			$_->update;
		}
		$guard->commit;
	}
	return 1;
}

sub create_user {
	my ( $self, $username, $password ) = @_;

	return unless $username and $password;

	unless ($self->config->prosody_running) {
		my $user = $self->find_user($username);
		die "user exists" if $user;
		my $db_user = $self->db->resultset('User')->create({
			username => $username,
			notes => 'Created account',
		});
		return $db_user;
	}

	my %xmpp_user_find = $self->xmpp->user($username);

	die "user exists" if %xmpp_user_find;

	my $prosody_user;
	my $db_user;

	$prosody_user = $self->xmpp->_prosody->_db->resultset('Prosody')->create({
		host => $self->config->prosody_userhost,
		user => lc($username),
		store => 'accounts',
		key => 'password',
		type => 'string',
		value => $password,
	});

	if ($prosody_user) {

		my $xmpp_data_check;

		$xmpp_data_check = Prosody::Mod::Data::Access->new(
			jid => lc($username).'@'.$self->config->prosody_userhost,
			password => $password,
		);
		
		if ($xmpp_data_check || !$self->config->prosody_running) {

			$db_user = $self->db->resultset('User')->create({
				username => $username,
				notes => 'Created account',
			});

		} else {

			$self->xmpp->_prosody->_db->resultset('Prosody')->search({
				host => $self->config->prosody_userhost,
				user => lc($username),
			})->delete;

		}

	}

	return unless $db_user;
	return $db_user;
}

sub find_user {
	my ( $self, $username ) = @_;

	return unless $username;

	my %xmpp_user;
	my $db_user;

	if ($self->config->prosody_running) {
		%xmpp_user = $self->xmpp->user(lc($username));
		return unless %xmpp_user;
		$db_user = $self->db->resultset('User')->search(\[
			'LOWER(me.username) LIKE ?',[ plain_value => lc($username)]
		])->first;
		unless ($db_user) {
			$db_user = $self->db->resultset('User')->create({
				username => $username,
				notes => 'Generated automatically based on prosody account',
			});
		}
	} else {
		$db_user = $self->db->resultset('User')->search(\[
			'LOWER(me.username) LIKE ?',[ plain_value => lc($username)]
		])->first;
		return unless $db_user;
	}

	return $db_user;
}

sub user_counts {
	my ( $self ) = @_;

  return $self->cache->get('ddgc_user_counts') if defined $self->cache->get('ddgc_user_counts');

	my %counts;
	$counts{db} = $self->db->resultset('User')->search({})->count;
	$counts{xmpp} = $self->config->prosody_running ? $self->xmpp->_prosody->_db->resultset('Prosody')->search({
		host => $self->config->prosody_userhost,
	},{
		group_by => 'user',
	})->count : 0;

	$self->cache->set('ddgc_user_counts',\%counts,"1 hour");

	return \%counts;
}

#
# ======== Comments ====================
#

sub add_comment { shift->forum->add_comment(@_) }

#
# ======== Misc ====================
#

no Moose;
__PACKAGE__->meta->make_immutable;
