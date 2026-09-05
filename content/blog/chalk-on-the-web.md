# Chalk on the Web

There's something satisfying about text that looks *hand-written*.

Digital typography is precise. Too precise. Real chalk crumbles,
leaves dust, and breaks across the grain of a blackboard.
SVG filters can simulate this:

```html
<filter id="chalk">
  <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" />
  <feDisplacementMap in="SourceGraphic" scale="1.4" />
  <feGaussianBlur stdDeviation="0.35" />
</filter>
```

The result? Text feels *alive* — like it was drawn
by hand on a classroom blackboard rather than rendered by a GPU.
