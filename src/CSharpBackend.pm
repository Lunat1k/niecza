use 5.010;
use strict;
use warnings;
use utf8;

package CSharpBackend;

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

# deliberately omitted for now: the run_once optimization & lazy static pad
# generation & indexification

our $unit;
our $nid = 0;
our @decls;
our @thaw;
our @cgs;
our %lpeers;
our %haslet;
our $libmode;

sub gsym {
    my ($type, $desc) = @_;
    $desc =~ s/(\W)/"_" . ord($1)/eg;
    my $base = 'G' . ($nid++) . $desc;
    my $full = $unit->name . "." . $base . ':f,' . $type;
    wantarray ? ($full, $base) : $full;
}

my $st_ty = 'Dictionary<string,BValue>';
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

    # 0s just set up variables
    # 1s set up subs
    # 2s set up objects
    # 3s set up relationships

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
    public static void Main() {
        Kernel.RunLoop(new SubInfo("boot", BOOT));
    }

EOM

    unless ($libmode) {
        $unit->visit_units_preorder(sub {
            $_->visit_local_packages(\&pkg2);
            $_->visit_local_stashes(\&stash2);
            $_->visit_local_subs_preorder(\&sub2);

            $_->visit_local_packages(\&pkg3);
            $_->visit_local_subs_preorder(\&sub3);

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
            push @thaw, CgOp::subcall(CgOp::rawsget($m->{peer}{ps}));
        });
        push @thaw, CgOp::return;

        push @cgs, CodeGen->new(csname => 'BOOT', usednamed => 1,
            ops => CgOp::prog(@thaw)->cps_convert(0))->csharp;
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
    my $p = $lpeers{$_} = gsym($st_ty, 'STASH');
    push @decls, $p;
    push @thaw, CgOp::rawsset($p, CgOp::rawnew($st_ty));
}

# xxx check for SAFE::
my %loopbacks = (
    'MCallFrame', 'Kernel.CallFrameMO',
    'MGatherIterator', 'RxFrame.GatherIteratorMO',
    'MList', 'Kernel.ListMO',
    'MMatch', 'RxFrame.MatchMO',
    'PAny', 'Kernel.AnyP',
    'PArray', 'Kernel.ArrayP',
    'PEMPTY', 'RxFrame.EMPTYP',
    'PHash', 'Kernel.HashP',
    'PStr', 'Kernel.StrP',
);

sub pkg0 {
    return unless $_->isa('Metamodel::Class');
    my $p   = $_->{peer}{mo} = gsym($cl_ty, $_->name);
    my $whv = $_->{peer}{what_var} = gsym('Variable', $_->name . '_WHAT');
    my $wh6 = $_->{peer}{what_ip6} = gsym('IP6', $_->name . '_WHAT');
    push @decls, $p, $whv, $wh6;
}

sub pkg2 {
    return unless $_->isa('Metamodel::Class');
    my $p   = $_->{peer}{mo};
    my $whv = $_->{peer}{what_var};
    my $wh6 = $_->{peer}{what_ip6};
    if ($unit->is_true_setting && ($_->name eq 'Scalar' ||
            $_->name eq 'Sub')) {
        push @thaw, CgOp::rawsset($p,
            CgOp::rawsget("Kernel." . $_->name . "MO:f,$cl_ty"));
    } else {
        push @thaw, CgOp::rawsset($p, CgOp::rawnew($cl_ty,
                CgOp::clr_string($_->name)));
        for my $a (@{ $_->attributes }) {
            push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'AddAttribute',
                CgOp::clr_string($a));
        }
    }
    for my $s (@{ $_->superclasses }) {
        push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'AddSuperclass',
            CgOp::rawsget($unit->deref($s)->{peer}{mo}));
    }
    push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'Complete');
    push @thaw, CgOp::rawsset($wh6, CgOp::rawnew('DynObject', CgOp::rawsget($p)));
    push @thaw, CgOp::setfield('slots', CgOp::cast('DynObject', CgOp::rawsget($wh6)), CgOp::null('object[]'));
    push @thaw, CgOp::setfield('typeObject', CgOp::rawsget($p), CgOp::rawsget($wh6));
    push @thaw, CgOp::rawsset($whv, CgOp::newscalar(CgOp::rawsget($wh6)));

    push @thaw, CgOp::rawsset($loopbacks{'P' . $_->name}, CgOp::rawsget($wh6))
        if $loopbacks{'P' . $_->name};
    push @thaw, CgOp::rawsset($loopbacks{'M' . $_->name}, CgOp::rawsget($p))
        if $loopbacks{'M' . $_->name};
}

sub pkg3 {
    return unless $_->isa('Metamodel::Class');
    my $p   = $_->{peer}{mo};
    for my $m (@{ $_->methods }) {
        push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'AddMethod',
            CgOp::clr_string($m->name),
            CgOp::rawsget($unit->deref($m->body)->{peer}{ps}));
    }
    for my $k (sort keys %{ $_->multi_regex_lists }) {
        for my $b (@{ $_->multi_regex_lists->{$k} }) {
            push @thaw, CgOp::rawcall(CgOp::rawsget($p), 'AddMultiRegex',
                CgOp::clr_string($k),
                CgOp::rawsget($unit->deref($b)->{peer}{ps}));
        }
    }
}

sub enter_code {
    my ($body) = @_;
    my @code;
    for my $ln (sort keys %{ $body->lexicals }) {
        my $lx = $body->lexicals->{$ln};

        if ($lx->isa('Metamodel::Lexical::SubDef')) {
            push @code, CgOp::Primitive->new(op => [ rtpadput => 0, $ln ],
                zyg => [ CgOp::newscalar(CgOp::rawscall('Kernel.MakeSub',
                            CgOp::rawsget($lx->body->{peer}{si}),
                            CgOp::callframe)) ]);
        } elsif ($lx->isa('Metamodel::Lexical::Simple')) {
            my $frag;
            next if $lx->noinit;
            if ($lx->hash || $lx->list) {
                # XXX should be SAFE::
                my $imp = $_->find_lex($lx->hash ? 'Hash' : 'Array')->path;
                my $var = $unit->deref($unit->get_stash($$imp)->obj)
                    ->{peer}{what_var};
                $frag = CgOp::methodcall(CgOp::rawsget($var), 'new');
            } else {
                $frag = CgOp::newblankrwscalar;
            }
            push @code, CgOp::Primitive->new(op => [ rtpadput => 0, $ln ],
                zyg => [ $frag ]);
        }
    }

    if (defined $body->signature) {
        push @code, $body->signature->binder($body);
    }
    @code;
}

sub access_lex {
    my ($body, $name, $set_to) = @_;

    if ($haslet{$name}) {
        return CgOp::letvar($name, $set_to);
    }

    my $bp = $body;
    my $order = 0;
    my $lex;
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
        return $set_to ?
            CgOp::Primitive->new(op => [ rtpadput => $order, $name ],
                zyg => [ $set_to ]) :
            CgOp::Primitive->new(op => [ rtpadget => 'Variable',$order,$name ]);
    } elsif ($lex->isa('Metamodel::Lexical::Stash')) {
        die "cannot rebind stashes" if $set_to;
        my $ref = $unit->get_stash(@{ $lex->path })->obj;
        my $obj = $ref && $unit->deref($ref);
        return $obj->{peer} ? CgOp::rawsget($obj->{peer}{what_var}) :
            CgOp::null('Variable');
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

    if ($op->isa('CgOp::Primitive')) {
        my ($opc, $arg, @rest) = @{ $op->op };
        if ($opc eq 'scopelex') {
            my $nn = access_lex($body, $arg, $op->zyg->[0]);
            #XXX
            %$op = %$nn;
            bless $op, ref($nn);
        }
    }

    if ($op->isa('CgOp::Let')) {
        local $haslet{$op->name} = 1;
        resolve_lex($body, $_) for @{ $op->zyg };
    } else {
        resolve_lex($body, $_) for @{ $op->zyg };
    }
}

sub codegen_sub {
    my @enter = enter_code($_);
    my $ops;
    # TODO: Bind a return value here to catch non-ro sub use
    if ($_->gather_hack) {
        $ops = CgOp::prog(@enter, CgOp::sink($_->code->cgop),
            CgOp::rawsccall('Kernel.Take', CgOp::scopedlex('EMPTY')));
    } elsif ($_->returnable && defined($_->signature)) {
        $ops = CgOp::prog(@enter,
            CgOp::return(CgOp::span("rstart", "rend",
                    $_->code->cgop)),
            CgOp::ehspan(4, undef, 0, "rstart", "rend", "rend"));
    } else {
        $ops = CgOp::prog(@enter, CgOp::return($_->code->cgop));
    }

    local %haslet;
    resolve_lex($_, $ops);
    CodeGen->new(csname => $_->{peer}{cbase}, ops => $ops->cps_convert(0),
        usednamed => 1);
}

# lumped under a sub are all the static-y lexicals
# protopads and proto-sub-instances need to exist early because methods, in
# particular, bind to them
# note: preorder
sub sub0 {
    my $node = ($_->{peer} = {});
    push @decls, ($node->{si} = gsym($si_ty, $_->name));
    push @decls, ($node->{ps} = gsym('IP6', $_->name . 'PS'));
    push @decls, ($node->{pp} = gsym('Frame', $_->name . 'PP'));
    @$node{'cref','cbase'} = gsym('DynBlockDelegate', $_->name . 'C');

    for my $ln (sort keys %{ $_->lexicals }) {
        my $lx = $_->lexicals->{$ln};

        if ($lx->isa('Metamodel::Lexical::Common')) {
            my $bv = $lx->{peer} = gsym('BValue', $lx->name);
            push @decls, $bv;
        }
    }
}

sub sub1 {
    my $node = $_->{peer};
    my $si = $node->{si};

    my $cg = codegen_sub($_);
    $node->{sictor} = [ $cg->subinfo_ctor_args(
            ($_->outer ? CgOp::rawsget($_->outer->{peer}{si}) :
                CgOp::null('SubInfo')),
            CgOp::null('LAD')) ];

    push @cgs, $cg->csharp;
}

sub sub2 {
    my $node = $_->{peer};
    my $si = $node->{si};

    push @thaw, CgOp::rawsset($si, CgOp::rawnew($si_ty, @{ $node->{sictor} }));

    my $pp = $node->{pp};
    push @thaw, CgOp::rawsset($pp, CgOp::rawnew('Frame',
            CgOp::null('Frame'), (!$_->outer ? CgOp::null('Frame') :
                CgOp::rawsget($_->outer->{peer}{pp})),
            CgOp::rawsget($si)));
    push @thaw, CgOp::setfield('lex', CgOp::rawsget($pp),
        CgOp::rawnew('Dictionary<string,object>'));

    my $ps = $node->{ps};
    push @thaw, CgOp::rawsset($ps, CgOp::rawscall('Kernel.MakeSub',
            CgOp::rawsget($si), !$_->outer ? CgOp::null('Frame') :
                CgOp::rawsget($_->outer->{peer}{pp})));
}

sub sub3 {
    for my $ln (sort keys %{ $_->lexicals }) {
        my $lx = $_->lexicals->{$ln};
        my $frag;

        if ($lx->isa('Metamodel::Lexical::Common')) {
            push @thaw, CgOp::rawsset($lx->{peer},
                CgOp::rawscall('Kernel.PackageLookup',
                    CgOp::rawsget($lpeers{$unit->get_stash($lx->path)}),
                    CgOp::clr_string($lx->name)));
        } elsif ($lx->isa('Metamodel::Lexical::SubDef')) {
            push @thaw, CgOp::setindex($ln,
                CgOp::getfield('lex', CgOp::rawsget($_->{peer}{pp})),
                CgOp::newscalar(CgOp::rawsget($lx->body->{peer}{ps})));
        } elsif ($lx->isa('Metamodel::Lexical::Simple')) {
            if ($lx->hash || $lx->list) {
                # XXX should be SAFE::
                my $imp = $_->find_lex($lx->hash ? 'Hash' : 'Array')->path;
                my $var = $unit->deref($unit->get_stash($$imp)->obj)
                    ->{peer}{what_var};
                $frag = CgOp::methodcall(CgOp::rawsget($var), 'new');
            } else {
                $frag = CgOp::newblankrwscalar;
            }
            push @thaw, CgOp::setindex($ln,
                CgOp::getfield('lex', CgOp::rawsget($_->{peer}{pp})),
                $frag);
        }
    }
}
