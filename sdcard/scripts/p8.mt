@Struct(cfg)
{ "value": 7, "name": "pico" }
@

@Vars
name  value;
 count  2;
@

@Action
p5.name  p5.value;
 $(cfg.name + "-" + count) $(count + 1);
@

@if((cfg.name + "-x") == "pico-x")
p5.ok;
   1;
@
