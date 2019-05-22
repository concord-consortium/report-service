export type ILaraResourceType = 'Activity' | 'Sequence';

export interface IPartialLaraAuthoredResource {
  url: string;
  author_email: string;
  type: ILaraResourceType;
}

export interface IPartialLaraRun {
  url: string;
  key: string;
  answers: IPartialLaraAnswer[]
}

export interface IPartialLaraAnswer {
  url: string;
  key: string;
}