#!/usr/bin/perl
# Copyright © 2006-2008 Joey Hess <joey@ikiwiki.info>
# Copyright © 2008 Simon McVittie <http://smcv.pseudorandom.co.uk/>
# Licensed under the GNU GPL, version 2, or any later version published by the
# Free Software Foundation
package IkiWiki::Plugin::smcvpostcomment;

use warnings;
use strict;
use IkiWiki 2.00;
use IkiWiki::Plugin::inline;
use IkiWiki::Plugin::mdwn;
use CGI 'escapeHTML';

use constant PLUGIN => "smcvpostcomment";
use constant PREVIEW => "Preview";
use constant POST_COMMENT => "Post comment";
use constant CANCEL => "Cancel";

sub import { #{{{
	hook(type => "getsetup", id => PLUGIN,  call => \&getsetup);
	hook(type => "preprocess", id => PLUGIN, call => \&preprocess);
	hook(type => "sessioncgi", id => PLUGIN, call => \&sessioncgi);
	hook(type => "htmlize", id => "_".PLUGIN,
		call => \&IkiWiki::Plugin::mdwn::htmlize);
	IkiWiki::loadplugin("inline");
} # }}}

sub getsetup () { #{{{
	return
		plugin => {
			safe => 1,
			rebuild => undef,
		},
} #}}}

# Somewhat based on IkiWiki::Plugin::inline blog posting support
sub preprocess (@) { #{{{
	my %params=@_;

	unless (length $config{cgiurl}) {
		error(sprintf (gettext("[[!%s plugin requires CGI enabled]]"),
			PLUGIN));
	}

	my $formtemplate = IkiWiki::template(PLUGIN . "_embed.tmpl",
		blind_cache => 1);
	$formtemplate->param(cgiurl => $config{cgiurl});
	$formtemplate->param(page => $params{page});

	if ($params{preview}) {
		$formtemplate->param("disabled" =>
			gettext('not available during Preview'));
	}

	debug("page $params{page} => destpage $params{destpage}");

	# I'm reasonably sure that this counts as abuse of [[!inline]]
	return $formtemplate->output . "\n" .
		IkiWiki::preprocess_inline(
			pages => "internal($params{page}/_comment_*)",
			template => PLUGIN . "_display",
			show => 0,
			reverse => "yes",
			page => $params{page},
			destpage => $params{destpage},
			preview => $params{preview});
} # }}}

# FIXME: logic taken from editpage, should be common code?
sub getcgiuser ($) { # {{{
	my $session = shift;
	my $user = $session->param('name');
	$user = $ENV{REMOTE_ADDR} unless defined $user;
	debug("getcgiuser() -> $user");
	return $user;
} # }}}

# FIXME: logic adapted from recentchanges, should be common code?
sub linkuser ($) { # {{{
	my $user = shift;
	my $oiduser = eval { IkiWiki::openiduser($user) };

	if (defined $oiduser) {
		return ($user, $oiduser);
	}
	else {
		my $page = bestlink('', (length $config{userdir}
				? "$config{userdir}/"
				: "").$user);
		return (urlto($page, undef, 1), $user);
	}
} # }}}

# FIXME: taken from IkiWiki::Plugin::editpage, should be common?
sub checksessionexpiry ($$) { # {{{
	my $session = shift;
	my $sid = shift;

	if (defined $session->param("name")) {
		if (! defined $sid || $sid ne $session->id) {
			error(gettext("Your login session has expired."));
		}
	}
} # }}}

# Mostly cargo-culted from IkiWiki::plugin::editpage
sub sessioncgi ($$) { #{{{
	my $cgi=shift;
	my $session=shift;

	my $do = $cgi->param('do');
	return unless $do eq PLUGIN;

	# These are theoretically configurable, but currently hard-coded
	my $allow_wikilinks = 0;
	my $allow_directives = 0;
	my $commit_comments = 1;

	IkiWiki::decode_cgi_utf8($cgi);

	eval q{use CGI::FormBuilder};
	error($@) if $@;

	my @buttons = (POST_COMMENT, PREVIEW, CANCEL);
	my $form = CGI::FormBuilder->new(
		fields => [qw{do sid page subject body}],
		charset => 'utf-8',
		method => 'POST',
		required => [qw{body}],
		javascript => 0,
		params => $cgi,
		action => $config{cgiurl},
		header => 0,
		table => 0,
		template => scalar IkiWiki::template_params(PLUGIN . '_form.tmpl'),
		# wtf does this do in editpage?
		wikiname => $config{wikiname},
	);

	IkiWiki::decode_form_utf8($form);
	IkiWiki::run_hooks(formbuilder_setup => sub {
			shift->(title => PLUGIN, form => $form, cgi => $cgi,
				session => $session, buttons => \@buttons);
		});
	IkiWiki::decode_form_utf8($form);

	$form->field(name => 'do', type => 'hidden');
	$form->field(name => 'sid', type => 'hidden', value => $session->id,
		force => 1);
	$form->field(name => 'page', type => 'hidden');
	$form->field(name => 'subject', type => 'text', size => 80);
	$form->field(name => 'body', type => 'textarea', rows => 5,
		cols => 80);

	# The untaint is OK (as in editpage) because we're about to pass
	# it to file_pruned anyway
	my $page = $form->field('page');
	$page = IkiWiki::possibly_foolish_untaint($page);
	if (!defined $page || !length $page ||
		IkiWiki::file_pruned($page, $config{srcdir})) {
		error(gettext("bad page name"));
	}

	# FIXME: is this right? Or should we be using the candidate subpage
	# (whatever that might mean) as the base URL?
	my $baseurl = urlto($page, undef, 1);

	$form->title(sprintf(gettext("commenting on %s"),
			IkiWiki::pagetitle($page)));

	$form->tmpl_param('helponformattinglink',
		htmllink($page, $page, 'ikiwiki/formatting',
			noimageinline => 1,
			linktext => 'FormattingHelp'));

	if (not exists $pagesources{$page}) {
		error(sprintf(gettext(
			"page '%s' doesn't exist, so you can't comment"),
			$page));
	}

	if ($form->submitted eq CANCEL) {
		# bounce back to the page they wanted to comment on, and exit.
		# CANCEL need not be considered in future
		IkiWiki::redirect($cgi, urlto($page, undef, 1));
		exit;
	}

	my ($authorurl, $author) = linkuser(getcgiuser($session));

	my $body = $form->field('body') || '';
	$body =~ s/\r\n/\n/g;
	$body =~ s/\r/\n/g;
	$body .= "\n" if $body !~ /\n$/;

	$body =~ s/\[\[([^!])/&#91;&#91;$1/g unless $allow_wikilinks;
	$body =~ s/\[\[!/&#91;&#91;!/g unless $allow_directives;

	# In this template, the [[!meta]] directives should stay at the end,
	# so that they will override anything the user specifies. (For
	# instance, [[!meta author="I can fake the author"]]...)
	my $content_tmpl = template(PLUGIN . '_comment.tmpl');
	$content_tmpl->param(author => $author);
	$content_tmpl->param(authorurl => $authorurl);
	$content_tmpl->param(subject => $form->field('subject'));
	$content_tmpl->param(body => $body);

	my $content = $content_tmpl->output;

	# This is essentially a simplified version of editpage:
	# - the user does not control the page that's created, only the parent
	# - it's always a create operation, never an edit
	# - this means that conflicts should never happen
	# - this means that if they do, rocks fall and everyone dies

	if ($form->submitted eq PREVIEW) {
		# $fake is a location that has the same number of slashes
		# as the eventual location of this comment.
		my $fake = "$page/_" . PLUGIN . "hypothetical";
		my $preview = IkiWiki::htmlize($fake, $page, 'mdwn',
				IkiWiki::linkify($page, $page,
					IkiWiki::preprocess($page, $page,
						IkiWiki::filter($fake, $page,
							$content),
						0, 1)));
		IkiWiki::run_hooks(format => sub {
				$preview = shift->(page => $page,
					content => $preview);
			});

		my $template = template(PLUGIN . "_display.tmpl");
		$template->param(content => $preview);
		$template->param(title => $form->field('subject'));
		$template->param(ctime => displaytime(time));
		$template->param(author => $author);
		$template->param(authorurl => $authorurl);

		$form->tmpl_param(page_preview => $template->output);
	}
	else {
		$form->tmpl_param(page_preview => "");
	}

	if ($form->submitted eq POST_COMMENT && $form->validate) {
		# Let's get posting. We don't check_canedit here because
		# that somewhat defeats the point of this plugin.

		checksessionexpiry($session, $cgi->param('sid'));

		# FIXME: check that the wiki is locked right now, because
		# if it's not, there are mad race conditions!

		# FIXME: rather a simplistic way to make the comments...
		my $i = 0;
		my $file;
		do {
			$i++;
			$file = "$page/_comment_${i}._" . PLUGIN;
		} while (-e "$config{srcdir}/$file");

		# FIXME: could probably do some sort of graceful retry
		# if I could be bothered
		writefile($file, $config{srcdir}, $content);

		my $conflict;

		if ($config{rcs} and $commit_comments) {
			my $message = gettext("Added a comment");
			if (defined $form->field('subject') &&
				length $form->field('subject')) {
				$message .= ": ".$form->field('subject');
			}

			IkiWiki::rcs_add($file);
			IkiWiki::disable_commit_hook();
			$conflict = IkiWiki::rcs_commit_staged($message,
				$session->param('name'), $ENV{REMOTE_ADDR});
			IkiWiki::enable_commit_hook();
			IkiWiki::rcs_update();
		}

		# Now we need a refresh
		require IkiWiki::Render;
		IkiWiki::refresh();
		IkiWiki::saveindex();

		# this should never happen, unless a committer deliberately
		# breaks it or something
		error($conflict) if defined $conflict;

		# Bounce back to where we were, but defeat broken caches
		my $anticache = "?updated=$page/_comment_$i";
		IkiWiki::redirect($cgi, urlto($page, undef, 1).$anticache);
	}
	else {
		IkiWiki::showform ($form, \@buttons, $session, $cgi,
			forcebaseurl => $baseurl);
	}

	exit;
} #}}}

1
