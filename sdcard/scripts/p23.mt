@Struct(cfg)
{ "items": [10, 20, 30], "name": "pico" }
@

@Vars
name  value;
 idx   1;
@

@Action
p5.value             p5.item             p5.name          p5.angle;
 $(cfg.items[idx+1]+1) $((cfg.items[idx]+5)*2) $(cfg.name+"-x") $(-3+5);
@

@if(cfg.items[idx+1] > 25 && (cfg.items[idx]*2 == 40) && !(1==2))
p5.value;
  99;
@
