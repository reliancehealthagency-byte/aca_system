import { signIn } from './actions';

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main style={{ maxWidth: 360 }}>
      <h1>Sign in</h1>
      {error ? <p style={{ color: '#b00' }}>Sign-in failed. Check your email and password.</p> : null}
      <form action={signIn} style={{ display: 'grid', gap: 8 }}>
        <label>
          Email
          <input name="email" type="email" required autoComplete="email" style={{ width: '100%' }} />
        </label>
        <label>
          Password
          <input name="password" type="password" required autoComplete="current-password" style={{ width: '100%' }} />
        </label>
        <button type="submit">Sign in</button>
      </form>
    </main>
  );
}
