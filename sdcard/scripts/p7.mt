@Struct(cfg)
{ "value": 7 }
@

@Vars
name  value;
 count  2;
@

@Action
p5.value  p5.item;
 $(cfg.value*count+1) $(cfg.value+1);
@

@if((count+2)*2==8)
p5.ok;
   1;
@
