@Struct(cfg)
{ "value": 7 }
@

@Vars
name  value;
 count  2;
@

@Action
p7.value  p7.item;
 $(cfg.value*count+1) $(cfg.value+1);
@

@if((count+2)*2==8)
p7.ok;
   1;
@
