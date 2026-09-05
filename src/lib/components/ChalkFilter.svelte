<!-- SVG filter definitions: chalk-on-blackboard -->
<script lang="ts">
	let {
		wobbleSeed = 42,
		chalkSeed = 8,
		boardSeed = 5
	}: {
		wobbleSeed?: number;
		chalkSeed?: number;
		boardSeed?: number;
	} = $props();
</script>

<svg style="position:absolute;width:0;height:0;overflow:hidden" aria-hidden="true">
	<defs>
		<!--
			Chalk writing: two-layer effect on live text.

			Layer 1 — Character wobble (low-freq displacement):
			Hand-drawn strokes are never perfectly uniform. Low-frequency
			noise with gentle displacement simulates the natural variation
			of a hand guiding chalk across a rough surface.

			Layer 2 — Chalk grain (high-freq displacement + blur):
			Chalk crumbles as it writes, leaving a rough, powdery edge
			rather than a clean line. High-frequency noise breaks the
			stroke into fine grain; a tiny gaussian blur softens the
			result into a powdery feel rather than jagged shards.

			Technique reference: blueprinter chalk.rs (production-tested).
		-->
		<filter id="chalk-writing" color-interpolation-filters="sRGB"
			x="-15%" y="-15%" width="130%" height="130%">
			<!-- Layer 1: character wobble -->
			<feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="3" seed={wobbleSeed} result="wobble-noise" />
			<feDisplacementMap in="SourceGraphic" in2="wobble-noise" scale="1.5"
				xChannelSelector="R" yChannelSelector="G" result="wobbled" />
			<!-- Layer 2: chalk grain breakup -->
			<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={chalkSeed} result="chalk-noise" />
			<feDisplacementMap in="wobbled" in2="chalk-noise" scale="1.0"
				xChannelSelector="R" yChannelSelector="G" result="grained" />
			<feGaussianBlur in="grained" stdDeviation="0.2" />
		</filter>

		<!--
			Board texture: coarser surface grain to simulate the
			uneven face of a slate blackboard.

			Parameter reference (1001ferramentas / Codrops):
			  Paper:       baseFrequency 0.6-0.9, numOctaves 2-3
			  Stone/slate:  baseFrequency 1.0-1.5, numOctaves 4-5
			  Concrete:     baseFrequency 1.5+,   numOctaves 5+
			Blackboard sits between paper and concrete.
		-->
		<filter id="board-texture" x="0" y="0" width="100%" height="100%">
			<feTurbulence type="fractalNoise" baseFrequency="1.0" numOctaves="4" seed={boardSeed} />
			<feColorMatrix type="saturate" values="0" />
		</filter>
	</defs>
</svg>
