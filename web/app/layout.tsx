import type { ReactNode } from 'react';

export const metadata = { title: 'Reliance backend: slice one', description: 'Seed-data dashboard' };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'system-ui, sans-serif', margin: '2rem', color: '#111' }}>{children}</body>
    </html>
  );
}
