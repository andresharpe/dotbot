/**
 * Custom React Flow edge for depends_on relationships.
 * Uses a smooth step path with an arrow marker.
 */
import { memo } from 'react';
import { BaseEdge, getSmoothStepPath, type EdgeProps } from '@xyflow/react';

function DependencyEdgeComponent(props: EdgeProps) {
  const {
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    style,
    markerEnd,
    selected,
  } = props;

  const [edgePath] = getSmoothStepPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    borderRadius: 12,
  });

  return (
    <BaseEdge
      path={edgePath}
      markerEnd={markerEnd}
      style={{
        ...style,
        stroke: selected ? 'var(--color-secondary)' : 'var(--primary-20)',
        strokeWidth: selected ? 2 : 1.5,
        filter: selected ? 'drop-shadow(0 0 4px var(--secondary-glow))' : undefined,
      }}
    />
  );
}

export const DependencyEdge = memo(DependencyEdgeComponent);
