@Struct(cfg)
{
  "value": 7,
  "inner": { "name": "pico" },
  "items": [10, 20]
}
@

@Action
p5.value  p5.name  p5.item;
 $(cfg.value) $(cfg.inner.name) $(cfg.items[1]);
@

@if(cfg.items[1]>10)
p5.ok;
   1;
@
