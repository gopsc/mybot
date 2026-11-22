@Struct(cfg)
{ "items": [10, 20, 30], "name": "pico-x" }
@

@Vars
name   value;
 idx    1;
 count  0;
@

@if((cfg.items[idx] == 20 && !(cfg.items[idx] > 25)) || cfg.name == "a && b")
p22.value;
  $(cfg.items[idx+1]);
@

@if(-3 + 5 == 2 && cfg.name == "pico-x")
p22.item;
  11;
@

@if((1 == 2 && missing > 0) || cfg.name == "pico-x")
p22.name;
  7;
@

@while((count < 3) && !(count == 2))
cnt.reading;
 $count=reading;
@

@if((count == 2) || (count > 5))
p22.angle;
  45;
@
