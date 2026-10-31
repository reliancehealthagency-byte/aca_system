import { changePassword } from './actions';
import { createClient } from '@/lib/supabase/server';

export default async function AccountPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  return (
    <main style={{ maxWidth: 360 }}>
      <h1>Change password</h1>
      <p>Signed in as {data.user?.email}</p>
      {ok ? <p style={{ color: '#070' }}>Password updated.</p> : null}
      {error ? <p style={{ color: '#b00' }}>Password not changed. Use at least 12 characters and make both fields match.</p> : null}
      <form action={changePassword} style={{ display: 'grid', gap: 8 }}>
        <label>
          New password
          <input name="password" type="password" required minLength={12} autoComplete="new-password" style={{ width: '100%' }} />
        </label>
        <label>
          Confirm new password
          <input name="confirm" type="password" required minLength={12} autoComplete="new-password" style={{ width: '100%' }} />
        </label>
        <button type="submit">Update password</button>
      </form>
      <p><a href="/">Back to dashboard</a></p>
    </main>
  );
}
