package Niecza::Pass::Beta;
use Optimizer::Beta;
use Moose;
sub run {
    my ($self,$ast) = @_;
    Optimizer::Beta::run($ast);
    $ast;
}
1;
