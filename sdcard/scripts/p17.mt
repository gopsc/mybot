@Struct(cfg)
{ "items": [10, 20, 30] }
@

@Vars
name  value;
 idx  1;
@

@Action
p5.value  p5.item;
 $(cfg.items[idx]) $(cfg.items[idx+1]);
@

@if(cfg.items[idx] > 10)
p5.ok;
   1;
@
