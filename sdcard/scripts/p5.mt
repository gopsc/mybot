@Struct(cfg)
{ "value": 7, "name": "pico" }
@

@Action
p5.value  p5.name;
 $(cfg.value) $(cfg.name);
@

@if(cfg.value>0)
p5.ok;
   1;
@
