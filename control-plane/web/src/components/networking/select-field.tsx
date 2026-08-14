import { Label } from "@/components/ui/label";

interface SelectFieldProps {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  children: React.ReactNode;
}

export function SelectField({
  id,
  label,
  value,
  onChange,
  children,
}: SelectFieldProps) {
  return (
    <div>
      <Label htmlFor={id}>{label}</Label>
      <select
        id={id}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
        required
      >
        {children}
      </select>
    </div>
  );
}
