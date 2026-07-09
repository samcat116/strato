interface DonutSegment {
  value: number;
  color: string;
}

interface AgentHealthDonutProps {
  segments: DonutSegment[];
  total: number;
}

const RADIUS = 42;
const STROKE = 13;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function AgentHealthDonut({ segments, total }: AgentHealthDonutProps) {
  const sum = segments.reduce((acc, s) => acc + s.value, 0);
  let offset = 0;

  return (
    <div className="relative h-[110px] w-[110px] shrink-0">
      <svg width={110} height={110} viewBox="0 0 110 110">
        <circle
          cx={55}
          cy={55}
          r={RADIUS}
          fill="none"
          className="stroke-muted"
          strokeWidth={STROKE}
        />
        {sum > 0 &&
          segments
            .filter((s) => s.value > 0)
            .map((s, i) => {
              const len = (s.value / sum) * CIRCUMFERENCE;
              const el = (
                <circle
                  key={i}
                  cx={55}
                  cy={55}
                  r={RADIUS}
                  fill="none"
                  stroke={s.color}
                  strokeWidth={STROKE}
                  strokeDasharray={`${len} ${CIRCUMFERENCE - len}`}
                  strokeDashoffset={-offset}
                  transform="rotate(-90 55 55)"
                />
              );
              offset += len;
              return el;
            })}
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="font-mono text-[22px] font-bold leading-none">{total}</span>
        <span className="mt-0.5 text-[9.5px] text-muted-foreground">agents</span>
      </div>
    </div>
  );
}
