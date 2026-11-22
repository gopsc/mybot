# P2-B: action alias + action var + $ref
@Alias
name  alias;
   A  angle;
@

@Vars
name  value;
   n  300;
@

@Action
rc0.A  rc0.n  t0.delay;
   45  $(n)      50;
@
