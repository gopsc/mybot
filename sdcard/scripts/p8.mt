@Struct(cfg)
{ "value": 7, "name": "pico" }
@

@Vars
name  value;
 count  2;
@

@Action
p8.name  p8.value;
 $(cfg.name + "-" + count) $(count + 1);
@

@if((cfg.name + "-x") == "pico-x")
p8.ok;
   1;
@
