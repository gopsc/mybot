@Action
hot.value;
   1;
@

@SQL
UPDATE P5Check SET value='77' WHERE name='hot';
@

@Action
hot.value;
   2;
@

@SQL
DROP TABLE P5Check;
@

@Action
hot.value;
   3;
@
