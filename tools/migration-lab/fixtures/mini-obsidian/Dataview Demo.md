# Dataview Demo

Inline field:: value

```dataview
TABLE file.name FROM "Notes"
```

```dataviewjs
dv.list(dv.pages().file.name)
```

Also `$= dv.current().file.name` and a tasks query line:

```tasks
not done
```
