'use server';

import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

// Lets a signed-in user change their own password. Runs with the user's own session (anon key + RLS).
export async function changePassword(formData: FormData) {
  const password = String(formData.get('password') ?? '');
  const confirm = String(formData.get('confirm') ?? '');
  if (password.length < 12 || password !== confirm) redirect('/account?error=invalid');
  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) redirect('/account?error=failed');
  redirect('/account?ok=1');
}
