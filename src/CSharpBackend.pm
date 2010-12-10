use 5.010;
use strict;
use warnings;
use utf8;

package CSharpBackend;

use constant NRINLINE => 10;

use Scalar::Util 'blessed';

my $VERBOSE = $ENV{NIECZA_CSHARP_VERBOSE};

# Input:  A Metamodel::Unit object
# Output: A CodeGenUnit object

# each StaticSub generates <some code> for the sub's body
# we also generate <some code> to build the runtime MOP (really, a thawer using
# CIL; a thaw using a custom format would be faster)

# StaticSub : SubInfo (handled partially in CodeGen itself)
# StaticSub : (opt) static pad, some static fields
# Stash     : Dictionary<string,BValue>
# Class     : DynMetaObject
# Class     : (opt) HOW

our $unit;
our $nid = 0;
our @decls;
our @thaw;
our @cgs;
our %lpeers;
our %haslet;
our $classhow;
our $libmode;

sub gsym {
    my ($type, $desc) = @_;
    $desc =~ s/(\W)/"_" . ord($1)/eg;
    my $base = 'G' . ($nid++) . $desc;
    my $full = $unit->name . "." . $base . ':f,' . $type;
    wantarray ? ($full, $base) : $full;
}

my $cl_ty = 'DynMetaObject';
my $si_ty = 'SubInfo';

sub run {
    local $unit = shift;
    local $libmode = $unit->name ne 'MAIN';
    local %lpeers;
    local $nid = 0;
    local @thaw;
    local @decls;
    local @cgs;
    local $classhow;

    local $Metamodel::unit = $unit;

    say STDERR $unit->name if $VERBOSE;

    # 0s just set up variables
    # 1s set up subs
    # 2s set up objects
    # 3s set up relationships

    $unit->ns->visit_stashes(\&stash2) unless $libmode; #XXX weird timing

    $unit->visit_local_packages(\&pkg0);
    $unit->visit_local_subs_preorder(\&sub0);

    $unit->visit_local_subs_preorder(\&sub1);

    my $mod = '';
    $mod .= <<EOH ;
using Niecza;
using System;
using System.Collections.Generic;

public class ${\ $unit->name } {
EOH
    $mod .= <<EOM unless $libmode ;
    public static void Main(string[] argv) {
        Kernel.commandArgs = argv;
        Kernel.RunLoop(new SubInfo("boot", BOOT));
    }

EOM

    unless ($libmode) {
        $unit->visit_units_preorder(sub {
            say STDERR "UNIT2: ", $_->name if $VERBOSE;
            $_->visit_local_packages(\&pkg2);
            $_->visit_local_subs_preorder(\&sub2);
        });
        $unit->visit_units_preorder(sub {
            say STDERR "UNIT3: ", $_->name if $VERBOSE;
            $unit->ns->visit_stashes(\&stash3) if $_ == $unit;
            $_->visit_local_packages(\&pkg3);
            $_->visit_local_subs_preorder(\&sub3);
        });
        push @thaw, CgOp::rawscall('Kernel.FirePhasers:m,Void',
            CgOp::int(0), CgOp::bool(0));
        $unit->visit_units_preorder(sub {
            say STDERR "UNIT4: ", $_->name if $VERBOSE;
            return if $_->bottom_ref;

            my $s = $_->setting;
            my $m = $_->mainline;
            while ($s) {
                my $su = $unit->get_unit($s);
                push @thaw, CgOp::setindex("*resume_$s",
                    CgOp::getfield("lex", CgOp::callframe),
                    CgOp::newscalar(CgOp::rawsget($m->{peer}{ps})));
                $s = $su->setting;
                $m = $su->mainline;
            }
            push @thaw, CgOp::sink(CgOp::subcall(CgOp::rawsget($m->{peer}{ps})));
        });
        push @thaw, CgOp::return;

        push @cgs, CodeGen->new(csname => 'BOOT', name => 'BOOT',
            usednamed => 1, ops => CgOp::prog(@thaw))->csharp;
    }

    for (@decls) {
        /(?:.*?\.)?(.*):f,(.*)/;
        $mod .= "    public static $2 $1;\n";
    }

    $mod .= $_ for (@cgs);
    $mod .= "}\n";

    $unit->{mod} = $mod;
    $unit;
}

sub stash2 {
    my ($path) = @_;
    say STDERR "stash2: @$path" if $VERBOSE;
    my $p = $lpeers{join "\0", @$path} = gsym('IP6', join('_',@$path));
    push @decls, $p;
    push @thaw, CgOp::rawsset($p, CgOp::fetch(CgOp::box(
            CgOp::rawsget('Kernel.StashP'),
            CgOp::rawnew('clr:Dictionary<string,BValue>'))));
    if (@$path == 1 && $path->[0] =~ /^(?:GLOBAL|PROCESS)$/) {
        push @thaw, CgOp::rawsset('Kernel.' . ucfirst(lc($path->[0])) .
            'O', CgOp::rawsget($p));
    }
}

sub stash3 {
    my ($path) = @_;
    say STDERR "stash3: @$path" if $VERBOSE;
    #my $p = $lpeers{join "\0", @$path};
    #for my $tup ($unit->ns->list_stash(@$path)) {
    #    my $ch = $_->zyg->{$k};
    #    my $bit;

    #    if ($tup->[1] eq 'pkg') {
    #        $bit = CgOp::newscalar(CgOp::rawsget($lpeers{join "\0", @$path, $tup->[0]}));
    #    } else {
    #        my $chd = $unit->deref($ch);
    #        if ($chd->isa('Metamodel::Package') &&
    #                defined $chd->{peer}{what_var}) {
    #            $bit = CgOp::rawsget($chd->{peer}{what_var});
    #        }
    #    }

    #    next unless $bit;
    #    push @thaw, CgOp::bset(CgOp::rawscall('Kernel.PackageLookup',
    #            CgOp::rawsget($p), CgOp::clr_string($k)), $bit);
    #}
}

my %loopbacks = (
    'MIterator', 'Kernel.IteratorMO',
    'MPair', 'Kernel.PairMO',
    'MCallFrame', 'Kernel.CallFrameMO',
    'MCapture', 'Kernel.CaptureMO',
    'MGatherIterator', 'Kernel.GatherIteratorMO',
    'MIterCursor', 'Kernel.IterCursorMO',
    'PAny', 'Kernel.AnyP',
    'PArray', 'Kernel.ArrayP',
    'PEMPTY', 'Kernel.EMPTYP',
    'PHash', 'Kernel.HashP',
    'PIterator', 'Kernel.IteratorP',
);

sub pkg0 {
    say STDERR "pkg0: ", $_->name if $VERBOSE;
    return unless $_->isa('Metamodel::Class') || $_->isa('Metamodel::Role')
        || $_->isa('Metamodel::ParametricRole');
    my $p   = $_->{peer}{mo} = gsym($cl_ty, $_->name);
    my $whv = $_->{peer}{what_var} = gsym('Variable', $_->name . '_WHAT');
    my $wh6 = $_->{peer}{what_ip6} = gsym('IP6', $_->name . '_WHAT');
    push @decls, $p, $whv, $wh6;
}

sub pkg2 {
    say STDERR "pkg2: ", $_->name if $VERBOSE;
    return unless $_->{peer};
    @_ = ($_->{peer}{mo}, $_->{peer}{what_ip6}, $_->{peer}{what_var});
    &pkg2_class if $_->isa('Metamodel::Class');
    &pkg2_role  if $_->isa('Metamodel::Role');
    &pkg2_prole if $_->isa('Metamodel::ParametricRole');
}

sub create_type_object {
    my $peer = shift;

    push @thaw, CgOp::rawsset($peer->{what_ip6},
        CgOp::rawnew('clr:DynObject', CgOp::rawsget($peer->{mo})));
    push @thaw, CgOp::setfield('slots',
        CgOp::cast('clr:DynObject', CgOp::rawsget($peer->{what_ip6})),
        CgOp::null('clr:object[]'));
    push @thaw, CgOp::setfield('typeObject', CgOp::rawsget($peer->{mo}),
        CgOp::rawsget($peer->{what_ip6}));
    push @thaw, CgOp::rawsset($peer->{what_var},
        CgOp::newscalar(CgOp::rawsget($peer->{what_ip6})));
}

sub pkg2_role {
    my ($p, $wh6, $whv) = @_;
    push @thaw, CgOp::rawsset($p, CgOp::rawnew("clr:$cl_ty",
            CgOp::clr_string($_->name)));
    push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'FillRole',
        CgOp::rawnewarr('str', map { CgOp::clr_string($_) }
            @{ $_->attributes }),
        CgOp::rawnewarr('clr:DynMetaObject',
            map { CgOp::rawsget($unit->deref($_)->{peer}{mo}) }
                @{ $_->superclasses }),
        CgOp::rawnewarr('clr:DynMetaObject'));

    create_type_object($_->{peer});
}

sub pkg2_prole {
    my ($p, $wh6, $whv) = @_;
    push @thaw, CgOp::rawsset($p, CgOp::rawnew("clr:$cl_ty",
            CgOp::clr_string($_->name)));

    create_type_object($_->{peer});
}

my %bootcl = (map { $_, 1 } qw/ Scalar Sub Stash Mu Str Bool Num Array Hash List Parcel Cursor Match Any /);
sub pkg2_class {
    my ($p, $wh6, $whv) = @_;
    my $punit = $unit->get_unit($_->xref->[0]);
    if ($punit->is_true_setting && $bootcl{$_->name}) {
        push @thaw, CgOp::rawsset($p,
            CgOp::rawsget("Kernel." . $_->name . "MO:f,$cl_ty"));
    } else {
        push @thaw, CgOp::rawsset($p, CgOp::rawnew("clr:$cl_ty",
                CgOp::clr_string($_->name)));
    }
    my $abase;
    for (@{ $_->linearized_mro }) {
        $abase += scalar @{ $unit->deref($_)->attributes };
    }
    push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'FillClass',
        CgOp::rawnewarr('str', map { CgOp::clr_string($_) }
            @{ $_->attributes }),
        CgOp::rawnewarr('str', map { CgOp::clr_string($_) }
            map { @{ $unit->deref($_)->attributes } } @{ $_->linearized_mro }),
        CgOp::rawnewarr('clr:DynMetaObject',
            map { CgOp::rawsget($unit->deref($_)->{peer}{mo}) }
                @{ $_->superclasses }),
        CgOp::rawnewarr('clr:DynMetaObject',
            map { CgOp::rawsget($unit->deref($_)->{peer}{mo}) }
                @{ $_->linearized_mro }));

    create_type_object($_->{peer});

    push @thaw, CgOp::rawsset($loopbacks{'P' . $_->name}, CgOp::rawsget($wh6))
        if $loopbacks{'P' . $_->name} && $punit->is_true_setting;
    push @thaw, CgOp::rawsset($loopbacks{'M' . $_->name}, CgOp::rawsget($p))
        if $loopbacks{'M' . $_->name} && $punit->is_true_setting;
    $classhow = $wh6 if $_->name eq 'ClassHOW' && $punit->is_true_setting;
}

sub pkg3 {
    say STDERR "pkg3: ", $_->name if $VERBOSE;
    return unless $_->isa('Metamodel::Class') || $_->isa('Metamodel::Role')
        || $_->isa('Metamodel::ParametricRole');
    for my $t (@{ $_->exports // []}) {
        my ($real, $n) = $unit->ns->stash_cname(@$t);
        if (!$lpeers{join "\0", @$real}) {
            Carp::confess "Stash peer has vanished: @$t / @$real $n";
        }
        push @thaw, CgOp::bset(CgOp::rawscall('Kernel.PackageLookup',
                CgOp::rawsget($lpeers{join "\0", @$real}),
                CgOp::clr_string($n)), CgOp::rawsget($_->{peer}{what_var}));
    }
    return if $_->isa('Metamodel::ParametricRole');
    my $p   = $_->{peer}{mo};
    for my $m (@{ $_->methods }) {
        push @thaw, CgOp::rawcall(CgOp::rawsget($p),
            ($m->private ? 'AddPrivateMethod' : 'AddMethod'),
            CgOp::clr_string($m->name),
            CgOp::rawsget($unit->deref($m->body)->{peer}{ps}));
    }
    push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'Invalidate');
    if ($classhow) {
        push @thaw, CgOp::setfield('how', CgOp::rawsget($p), CgOp::fetch(
                CgOp::box(CgOp::rawsget($classhow), CgOp::rawsget($p))));
    }
}

sub enter_code {
    my ($body) = @_;
    my @code;
    for my $ln (sort keys %{ $body->lexicals }) {
        my $lx = $body->lexicals->{$ln};

        next if $body->run_once && $body->spad_exists && !dynname($ln);

        if ($lx->isa('Metamodel::Lexical::SubDef')) {
            push @code, access_lex($body, $ln,
                CgOp::newscalar(CgOp::rawscall('Kernel.MakeSub',
                        CgOp::rawsget($lx->body->{peer}{si}),
                        CgOp::callframe)), 0);
        } elsif ($lx->isa('Metamodel::Lexical::Simple')) {
            my $frag;
            next if $lx->noinit;
            if ($lx->hash || $lx->list) {
                my $imp = $_->true_setting->find_lex($lx->hash ? 'Hash' : 'Array')->path;
                my $var = $unit->deref($unit->get_item(@$imp))
                    ->{peer}{what_var};
                $frag = CgOp::methodcall(CgOp::rawsget($var), 'new');
            } else {
                $frag = CgOp::newblankrwscalar;
            }
            push @code, access_lex($body, $ln, $frag, 0);
        }
    }
novars:

    @code;
}

sub access_lex {
    my ($body, $name, $set_to, $core) = @_;

    if ($haslet{$name} && !$core) {
        return CgOp::letvar($name, $set_to);
    }

    my $bp = $body;
    my $order = 0;
    my $lex;
    $bp = $bp->true_setting if $core;
    while ($bp) {
        $lex = $bp->lexicals->{$name};
        if (!$lex) {
            $bp = $bp->outer;
            $order++;
        } elsif ($lex->isa('Metamodel::Lexical::Alias')) {
            $name = $lex->to;
        } else {
            last;
        }
    }

    if (!defined($lex)) {
        die "Internal error: failed to resolve lexical $name in " . $body->name;
    }

    if ($lex->isa('Metamodel::Lexical::SubDef') ||
            $lex->isa('Metamodel::Lexical::Simple')) {
        if ($bp->run_once && !dynname($name)) {
            return $set_to ? CgOp::rawsset($lex->{peer}, $set_to) :
                CgOp::rawsget($lex->{peer});
        } else {
            my $ix = $lex->{peer};
            return $set_to ?
                CgOp->new(op => [ rtpadputi => $order, $ix ],
                    zyg => [ $set_to ]) :
                CgOp->new(op => [ rtpadgeti => 'Variable', $order, $ix ]);
        }
    } elsif ($lex->isa('Metamodel::Lexical::Stash')) {
        die "cannot rebind stashes" if $set_to;
        my $ref = $unit->get_item(@{ $lex->path });
        my $obj = $ref && $unit->deref($ref);
        return $obj->{peer} ? CgOp::rawsget($obj->{peer}{what_var}) :
            CgOp::null('var');
    } elsif ($lex->isa('Metamodel::Lexical::Common')) {
        return $set_to ?
            CgOp::bset(CgOp::rawsget($lex->{peer}), $set_to) :
            CgOp::bget(CgOp::rawsget($lex->{peer}));
    } else {
        die "unhandled $lex";
    }
}

sub resolve_lex {
    my ($body, $op) = @_;

    my ($opc, $arg, @rest) = @{ $op->op };
    if ($opc eq 'scopelex' || $opc eq 'corelex') {
        my $nn = access_lex($body, $arg, $op->zyg->[0], $opc eq 'corelex');
        #XXX
        %$op = %$nn;
        bless $op, ref($nn);

        resolve_lex($body, $_) for @{ $op->zyg };
    } elsif ($opc eq 'class_ref') {
        my $cl = (@rest > 1) ? $unit->deref([ @rest ]) :
            $unit->deref($unit->get_item(@{$body->find_lex(@rest)->path}));
        my $nn = CgOp::rawsget($cl->{peer}{$arg});
        %$op = %$nn;
        bless $op, ref($nn);
    } elsif ($opc eq 'call_uncloned_sub') {
        my $sr = $unit->deref([ $arg, @rest ]);
        my $nn = CgOp::subcall(CgOp::rawscall('Kernel.MakeSub',
                CgOp::rawsget($sr->{peer}{si}), CgOp::callframe()));
        %$op = %$nn;
        bless $op, ref($nn);
    } elsif ($opc eq 'let') {
        local $haslet{$arg} = 1;

        resolve_lex($body, $_) for @{ $op->zyg };
    } else {
        resolve_lex($body, $_) for @{ $op->zyg };
    }
}

sub codegen_sub {
    my @enter = enter_code($_);
    my $ops;
    # XXX sub1 will only be done once per sub, and code is never introspected
    # (it's in a sucky format anyway), so this is safe, and it makes dumps
    # much smaller.
    my $code = delete $_->{code};
    my @dynames;
    my @dyixes;
    for my $ln (sort keys %{ $_->lexicals }) {
        next unless dynname($ln);
        push @dynames, $ln;
        push @dyixes, $_->lexicals->{$ln}{peer};
    }

    # TODO: Bind a return value here to catch non-ro sub use
    if ($_->gather_hack) {
        $ops = CgOp::prog(@enter, CgOp::sink($code->cgop($_)),
            CgOp::rawscall('Kernel.Take', CgOp::corelex('EMPTY')));
    } elsif ($_->augment_hack) {
        my @prg;
        my ($class, @tuples) = @{ $_->augment_hack };
        for my $tuple (@tuples) {
            push @prg, CgOp::rawcall(CgOp::letvar('!mo'),
                ($tuple->[0] ? 'AddPrivateMethod' : 'AddMethod'),
                CgOp::clr_string($tuple->[1]),
                CgOp::scopedlex($tuple->[2]));
        }
        $ops = CgOp::letn('!mo', CgOp::class_ref('mo', @$class),
            @prg, CgOp::rawcall(CgOp::letvar('!mo'), 'Invalidate'),
            CgOp::return);
    } elsif ($_->parametric_role_hack) {
        my $obj = $unit->deref($_->parametric_role_hack);
        my @build;
        push @build, CgOp::rawcall(CgOp::letvar('!mo'), "FillRole",
            CgOp::rawnewarr('str', map { CgOp::clr_string($_) }
                @{ $obj->attributes }),
            CgOp::rawnewarr('clr:DynMetaObject',
                map { CgOp::rawsget($unit->deref($_)->{peer}{mo}) }
                @{ $obj->superclasses }),
            CgOp::rawnewarr('clr:DynMetaObject'));
        for my $m (@{ $obj->methods }) {
            push @build, CgOp::rawcall(CgOp::letvar('!mo'),
                ($m->[2] ? 'AddPrivateMethod' : 'AddMethod'),
                (ref($m->[0]) ?
                    CgOp::unbox('str', CgOp::fetch($m->[0]->cgop($_))) :
                    CgOp::clr_string($m->[0])),
                CgOp::fetch(CgOp::scopedlex($m->[1])));
        }
        push @build, CgOp::rawcall(CgOp::letvar('!mo'), 'Invalidate');
        if ($_->signature) {
            for my $p (@{ $_->signature->params }) {
                next unless $p->slot;
                push @build, CgOp::varhash_setindex($p->slot,
                    CgOp::letvar('!pa'), CgOp::scopedlex($p->slot));
            }
        }
        $ops = CgOp::prog(@enter, CgOp::sink($code->cgop($_)),
            CgOp::letn("!mo", CgOp::rawnew('clr:DynMetaObject',
                    CgOp::clr_string($obj->name)),
                "!to", CgOp::rawnew('clr:DynObject', CgOp::letvar('!mo')),
                "!pa", CgOp::varhash_new(),
                @build,
                CgOp::scopedlex('*params', CgOp::letvar('!pa')),
                CgOp::setfield('slots', CgOp::letvar('!to'),
                    CgOp::null('clr:object[]')),
                CgOp::setfield('typeObject', CgOp::letvar('!mo'),
                    CgOp::letvar('!to')),
                CgOp::return(CgOp::newscalar(CgOp::letvar('!to')))));
    } elsif ($_->returnable) {
        $ops = CgOp::prog(@enter,
            CgOp::return(CgOp::span("rstart", "rend", 0,
                    $code->cgop($_))),
            CgOp::ehspan(4, undef, 0, "rstart", "rend", "rend"));
    } else {
        $ops = CgOp::prog(@enter, CgOp::return($code->cgop($_)));
    }

    local %haslet;
    resolve_lex($_, $ops);
    CodeGen->new(csname => $_->{peer}{cbase}, name => ($_->name eq 'ANON' ?
            $_->{peer}{cbase} : $_->name), ops => $ops,
        dynames => \@dynames, dyixes => \@dyixes, minlets => $_->{peer}{nlexn});
}

sub dynname { $_[0] eq '$_' || $_[0] =~ /^.?[*?]/ }
# lumped under a sub are all the static-y lexicals
# protopads and proto-sub-instances need to exist early because methods, in
# particular, bind to them
# note: preorder
sub sub0 {
    say STDERR "sub0: ", $_->name if $VERBOSE;
    my $node = ($_->{peer} = {});
    push @decls, ($node->{si} = gsym($si_ty, $_->name));
    push @decls, ($node->{ps} = gsym('IP6', $_->name . 'PS'))
        if !$_->outer || $_->outer->spad_exists;
    push @decls, ($node->{pp} = gsym('Frame', $_->name . 'PP'))
        if $_->spad_exists;
    @$node{'cref','cbase'} = gsym('DynBlockDelegate', $_->name . 'C');

    my ($nlexn) = (0);

    for my $ln (sort keys %{ $_->lexicals }) {
        my $lx = $_->lexicals->{$ln};

        if ($lx->isa('Metamodel::Lexical::Common')) {
            my $bv = $lx->{peer} = gsym('BValue', $lx->name);
            push @decls, $bv;
        }

        if ($lx->isa('Metamodel::Lexical::SubDef') ||
                $lx->isa('Metamodel::Lexical::Simple')) {
            if ($_->run_once && !dynname($ln)) {
                push @decls, ($lx->{peer} = gsym('Variable', $ln));
            } else {
                $lx->{peer} = ($nlexn++);
            }
        }
    }

    @$node{'nlexn'} = ($nlexn);
}

sub sub1 {
    say STDERR "sub1: ", $_->name if $VERBOSE;
    my $node = $_->{peer};
    my $si = $node->{si};

    my $cg = codegen_sub($_);
    $node->{sictor} = [ $cg->subinfo_ctor_args(
            ($_->outer ? CgOp::rawsget($_->outer->{peer}{si}) :
                CgOp::null('clr:SubInfo')),
            ($_->ltm ? CgOp::construct_lad($_->ltm) : CgOp::null('lad'))) ];

    push @cgs, $cg->csharp;
}

sub sub2 {
    say STDERR "sub2: ", $_->name if $VERBOSE;
    my $node = $_->{peer};
    my $si = $node->{si};

    push @thaw, CgOp::rawsset($si, CgOp::rawnew("clr:$si_ty", @{ $node->{sictor} }));

    if ($_->class ne 'Sub') {
        my $pkg = $_->true_setting->find_lex_pkg($_->class) //
            Carp::confess("Cannot resolve sub type " . $_->class . " for " . $_->name);
        my $cl = $unit->deref($unit->get_item(@$pkg));
        push @thaw, CgOp::setfield('mo', CgOp::rawsget($si), CgOp::rawsget($cl->{peer}{mo}));
    }

    my $pp = $node->{pp};
    if ($pp) {
        push @thaw, CgOp::rawsset($pp, CgOp::rawnew('clr:Frame',
                CgOp::null('clr:Frame'), (!$_->outer ? CgOp::null('clr:Frame') :
                    CgOp::rawsget($_->outer->{peer}{pp})),
                CgOp::rawsget($si)));
        if ($node->{uname}) {
            push @thaw, CgOp::setfield('lex', CgOp::rawsget($pp),
                CgOp::rawnew('clr:Dictionary<string,object>'));
        }
        if ($node->{nlexn} > NRINLINE) {
            push @thaw, CgOp::setfield('lexn', CgOp::rawsget($pp),
                CgOp::rawnewzarr('clr:object', CgOp::int($node->{nlexn} - NRINLINE)));
        }
    }

    my $ps = $node->{ps};
    if ($ps) {
        push @thaw, CgOp::rawsset($ps, CgOp::rawscall('Kernel.MakeSub',
                CgOp::rawsget($si), !$_->outer ? CgOp::null('clr:Frame') :
                    CgOp::rawsget($_->outer->{peer}{pp})));
        if ($_->parametric_role_hack) {
            push @thaw, CgOp::rawcall(
                CgOp::rawsget($unit->deref($_->parametric_role_hack)
                    ->{peer}{mo}), "FillParametricRole", CgOp::rawsget($ps));
        }
    }
}

# use for SubDef / Simple only
sub protolset {
    my ($body, $lname, $lex, $frag) = @_;

    if ($body->run_once && !dynname($lname)) {
        push @thaw, CgOp::rawsset($lex->{peer}, $frag);
    } elsif ((my $ix = $lex->{peer}) >= NRINLINE) {
        push @thaw, CgOp::setindex(CgOp::int($ix - NRINLINE),
            CgOp::getfield('lexn', CgOp::rawsget($body->{peer}{pp})),
            $frag);
    } else {
        push @thaw, CgOp::setfield("lex$ix",
            CgOp::rawsget($body->{peer}{pp}), $frag);
    }
}

sub encode_parameter {
    my ($b, $p, $i, $r) = @_;
    my $fl = 0;
    push @$r, CgOp::clr_string($p->name);
    push @$r, map { CgOp::clr_string($_) } @{ $p->names };

    # Keep in sync with SIG_F_XXX defines
    # TODO type constraints
    if ($p->rwtrans) {
        $fl |= 8;
    } elsif (!$p->readonly) {
        $fl |= 2;
    }
    $fl |= 16 if ($p->hash || $p->list);
    if (defined $p->mdefault) {
        $fl |= 32;
        push @$r, CgOp::rawsget($p->mdefault->{peer}{si});
    }
    $fl |= 64 if $p->optional;
    $fl |= 128 if $p->positional;
    $fl |= 256 if $p->slurpy && !$p->hash;
    $fl |= 512 if $p->slurpy && $p->hash;
    $fl |= 1024 if $p->slurpycap;
    $fl |= 2048 if $p->full_parcel;

    push @$i, $fl;
    push @$i, defined($p->slot) ? $b->lexicals->{$p->slot}{peer} : -1;
    push @$i, scalar(@{ $p->names });
}

sub sub3 {
    say STDERR "sub3: ", $_->name if $VERBOSE;
    if (defined $_->signature) {
        my @i; my @r; my $b = $_;
        for (@{ $_->signature->params }) { encode_parameter($b, $_, \@i, \@r); }
        push @thaw, CgOp::setfield("sig_i", CgOp::rawsget($_->{peer}{si}),
            CgOp::rawnewarr('int', map { CgOp::int($_) } @i));
        push @thaw, CgOp::setfield("sig_r", CgOp::rawsget($_->{peer}{si}),
            CgOp::rawnewarr('clr:object', @r));
    }
    if (defined $_->is_phaser) {
        push @thaw, CgOp::rawscall('Kernel.AddPhaser:m,Void',
            CgOp::int($_->is_phaser), CgOp::rawsget($_->{peer}{ps}));
    }
    for my $t (@{ $_->exports // []}) {
        my ($real, $n) = $unit->ns->stash_cname(@$t);
        push @thaw, CgOp::bset(CgOp::rawscall('Kernel.PackageLookup',
                CgOp::rawsget($lpeers{join "\0", @$real}),
                CgOp::clr_string($n)), CgOp::newscalar(CgOp::rawsget($_->{peer}{ps})));
    }
    for my $ln (sort keys %{ $_->lexicals }) {
        my $lx = $_->lexicals->{$ln};
        my $frag;

        if ($lx->isa('Metamodel::Lexical::Common')) {
            my ($stash, $final) = $unit->ns->stash_cname(@{ $lx->path }, $lx->name);
            if (!$lpeers{join "\0", @$stash}) {
                Carp::confess("Peer for " . join("::", @{ $stash }) . " has gone missing!");
            }
            push @thaw, CgOp::rawsset($lx->{peer},
                CgOp::rawscall('Kernel.PackageLookup',
                    CgOp::rawsget($lpeers{join "\0", @$stash}),
                    CgOp::clr_string($final)));
        } elsif ($lx->isa('Metamodel::Lexical::SubDef')) {
            next unless $_->spad_exists;
            protolset($_, $ln, $lx,
                CgOp::newscalar(CgOp::rawsget($lx->body->{peer}{ps})));
        } elsif ($lx->isa('Metamodel::Lexical::Simple')) {
            next unless $_->spad_exists;
            if ($lx->hash || $lx->list) {
                my $imp = $_->true_setting->find_lex($lx->hash ? 'Hash' : 'Array')->path;
                my $var = $unit->deref($unit->get_item(@$imp))
                    ->{peer}{what_var};
                $frag = CgOp::methodcall(CgOp::rawsget($var), 'new');
            } else {
                $frag = CgOp::newblankrwscalar;
            }
            protolset($_, $ln, $lx, $frag);
        }
    }
}
