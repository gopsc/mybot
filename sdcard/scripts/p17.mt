@Struct(cfg)
{ "items": [10, 20, 30] }
@

@Vars
name  value;
 idx  1;
@

@Action
p17.value  p17.item;
 $(cfg.items[idx]) $(cfg.items[idx+1]);
@

@if(cfg.items[idx] > 10)
p17.ok;
   1;
@
