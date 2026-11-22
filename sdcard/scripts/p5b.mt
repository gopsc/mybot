@Struct(cfg)
{
  "value": 7,
  "inner": { "name": "pico" },
  "items": [10, 20]
}
@

@Action
p5b.value  p5b.name  p5b.item;
 $(cfg.value) $(cfg.inner.name) $(cfg.items[1]);
@

@if(cfg.items[1]>10)
p5b.ok;
   1;
@
