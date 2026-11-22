@Struct(cfg)
{ "value": 0 }
@

@Action
cnt.reading;
 $cfg.value=reading;
@

@Action
p5.value;
 $(cfg.value);
@
