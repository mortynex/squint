import { useState, type ReactNode } from "react";

interface User { id: number; name: string; email?: string }

/** Fetch a user from the API. */
export async function getUser(id: number): Promise<User | null> {
  const res = await fetch(`/api/users/${id}`, { headers: { "Accept": "application/json" } });
  if (!res.ok) return null;
  return (await res.json()) as User;
}

export const Counter = ({ children }: { children: ReactNode }) => {
  const [count, setCount] = useState(0);
  return <button onClick={() => setCount(c => c + 1)}>{children} {count}</button>;
};
