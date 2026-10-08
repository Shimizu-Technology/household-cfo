// @vitest-environment jsdom
import {useEffect} from 'react'
import {cleanup,fireEvent,render,screen,waitFor} from '@testing-library/react'
import {afterEach,expect,it,vi} from 'vitest'
import {AuthProvider} from './AuthContext'
import {useAuthContext} from './authContextValue'
const observed=vi.hoisted(()=>({completion:false,states:[] as string[]}))
vi.mock('../lib/authPopup',async importOriginal=>({...await importOriginal<typeof import('../lib/authPopup')>(),openAuthPopup:()=>({close:vi.fn(),location:{href:''}}),navigateAuthPopup:vi.fn(),watchAuthPopup:async(_popup:Window,read:(confirmed:boolean)=>Promise<unknown>)=>read(true)}))
afterEach(()=>{cleanup();vi.unstubAllGlobals();observed.completion=false;observed.states=[]})
it('Google completion uses one checked session result without reopening the signed-out screen',async()=>{
 const clientId='client_FICTIONAL1';let signedIn=false;let sessionReads=0;
 const session={client_id:clientId,user:{id:'user_STARTUP',email:'fictional@pilot.test'},organization_id:null,authentication_method:'GoogleOAuth',access_token:'fictional-memory-token',expires_at:new Date(Date.now()+120_000).toISOString()};
 const url=new URL('https://api.workos.com/user_management/authorize');url.searchParams.set('client_id',clientId);url.searchParams.set('redirect_uri',`${window.location.origin}/api/auth/callback`);url.searchParams.set('state','s'.repeat(43));
 vi.stubGlobal('fetch',vi.fn(async(input)=>{const path=String(input);if(path.endsWith('/api/auth/session')){sessionReads++;return Response.json(signedIn?session:{client_id:clientId,user:null})}if(path.endsWith('/api/auth/options'))return Response.json({google_enabled:true});if(path.endsWith('/api/auth/login'))return Response.json({authorization_url:url.href});if(path.endsWith('/api/auth/login/status')){signedIn=true;observed.completion=true;return Response.json({status:'complete'})}if(path.endsWith('/api/v1/auth/me'))return Response.json({user:{id:17,auth_provider:'workos',auth_subject:'user_STARTUP'}});throw new Error('Unexpected fictional startup request')}));
 function Entry(){const auth=useAuthContext();useEffect(()=>{if(observed.completion)observed.states.push(auth.isLoading?'opening':auth.currentUser?'verified':auth.isSignedIn?'verifying':'signed-out')},[auth]);return <><p>{auth.currentUser?'Verified account':'Closed workspace'}</p><button onClick={()=>void auth.signIn?.()}>Open sign in</button></>}
 render(<AuthProvider provider="workos" clientId={clientId}><Entry/></AuthProvider>);await waitFor(()=>expect(sessionReads).toBe(1));fireEvent.click(screen.getByRole('button',{name:'Open sign in'}));fireEvent.click(await screen.findByRole('button',{name:'Continue with Google'}));await screen.findByText('Verified account');expect(screen.queryByRole('dialog')).toBeNull();expect(observed.states).not.toContain('signed-out');expect(sessionReads).toBe(3);
})
