$env:cjStackSize="64MB"
$env:cjHeapSize="64MB"
cjpm run --run-args="$($args -join ' ')"
